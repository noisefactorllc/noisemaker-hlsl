// Parser.cs — recursive-descent parser, a 1:1 port of shaders/src/lang/parser.js
// (reference/01 §2-§7). Produces a ProgramNode AST.
//
// PARITY-CRITICAL behaviors replicated:
//  - Numeric +-*/ are CONSTANT-FOLDED at parse time in DOUBLE, left-to-right within a
//    precedence level; operands MUST be Number literals (else "Expected number")
//    (reference/01 §4.4). Math.PI = 3.141592653589793.
//  - HEX color parse: parseInt(pair,16)/255 in double; 3-digit char duplication; alpha
//    default 1.0; 8-digit alpha A/255 (reference/01 §5).
//  - Special-form transforms in order: from, osc (4-way heuristic), midi, audio, read,
//    read3d (reference/01 §4.2).
//  - memberTokenTypes / exprStartTokens / namespaceTokenTypes membership (reference/01 §2.1).
//  - `search` mandatory + position-restricted; `render` terminates the program;
//    duplicate render throws (reference/01 §3.1).
//  - Inline namespace `a.b()` forbidden; member-dot-then-call lookahead (reference/01 §4.2.2/§4.3).
//
// Pure C#, no UnityEngine. Throws DslSyntaxError. Namespace validity comes from the
// EffectRegistry (reference/01 §3.2: VALID_NAMESPACES is manifest-populated).

using System.Collections.Generic;

namespace Noisemaker.Hlsl.Compiler
{
    public sealed class Parser
    {
        private readonly List<Token> _tokens;
        private int _current;
        private readonly EffectRegistry _registry;

        private List<string> _programSearchOrder; // null until `search` parsed
        private readonly NamespaceMeta _programNamespace = new NamespaceMeta();

        private static readonly HashSet<TokenType> ExprStart = new HashSet<TokenType>
        {
            TokenType.PLUS, TokenType.MINUS, TokenType.NUMBER, TokenType.HEX, TokenType.FUNC,
            TokenType.STRING, TokenType.IDENT, TokenType.OUTPUT_REF, TokenType.SOURCE_REF,
            TokenType.VOL_REF, TokenType.GEO_REF, TokenType.MESH_REF, TokenType.XYZ_REF,
            TokenType.VEL_REF, TokenType.RGBA_REF, TokenType.LPAREN, TokenType.LBRACKET,
            TokenType.TRUE, TokenType.FALSE
        };

        private static readonly HashSet<TokenType> MemberTokens = new HashSet<TokenType>
        {
            TokenType.IDENT, TokenType.SOURCE_REF, TokenType.OUTPUT_REF, TokenType.VOL_REF,
            TokenType.GEO_REF, TokenType.MESH_REF, TokenType.XYZ_REF, TokenType.VEL_REF,
            TokenType.RGBA_REF, TokenType.LET, TokenType.RENDER, TokenType.TRUE,
            TokenType.FALSE, TokenType.IF, TokenType.ELIF, TokenType.ELSE, TokenType.BREAK,
            TokenType.CONTINUE, TokenType.RETURN, TokenType.WRITE, TokenType.WRITE3D,
            TokenType.SUBCHAIN
        };

        private static readonly HashSet<TokenType> NamespaceTokens = new HashSet<TokenType>
        {
            TokenType.IDENT, TokenType.RENDER, TokenType.WRITE, TokenType.WRITE3D,
            TokenType.TRUE, TokenType.FALSE, TokenType.IF, TokenType.ELIF, TokenType.ELSE,
            TokenType.BREAK, TokenType.CONTINUE, TokenType.RETURN
        };

        private Parser(List<Token> tokens, EffectRegistry registry)
        {
            _tokens = tokens;
            _registry = registry;
            _current = 0;
        }

        public static ProgramNode Parse(List<Token> tokens, EffectRegistry registry)
        {
            return new Parser(tokens, registry).ParseProgram();
        }

        // --- cursor helpers -------------------------------------------------

        private Token Peek() { return _tokens[_current]; }
        private Token TokenAt(int idx) { return (idx >= 0 && idx < _tokens.Count) ? _tokens[idx] : null; }
        private Token Advance() { return _tokens[_current++]; }
        private Token Expect(TokenType type, string msg)
        {
            Token t = Peek();
            if (t.Type == type) return Advance();
            throw DslSyntaxError.At(msg, t.Line, t.Col);
        }

        private List<string> CollectComments()
        {
            var comments = new List<string>();
            while (Peek() != null && Peek().Type == TokenType.COMMENT)
                comments.Add(Advance().Lexeme);
            return comments;
        }

        // --- program (reference/01 §3.1) ------------------------------------

        private ProgramNode ParseProgram()
        {
            var plans = new List<Node>();
            var vars = new List<VarAssignNode>();
            OutputRefNode render = null;
            var trailingComments = new List<string>();

            while (Peek().Type != TokenType.EOF)
            {
                if (Peek().Type == TokenType.SEMICOLON) { Advance(); continue; }
                List<string> leadingComments = CollectComments();
                if (Peek().Type == TokenType.EOF)
                {
                    if (leadingComments.Count > 0) trailingComments.AddRange(leadingComments);
                    break;
                }
                if (Peek().Type == TokenType.SEARCH)
                {
                    if (plans.Count > 0 || vars.Count > 0 || render != null)
                    {
                        Token t = Peek();
                        throw DslSyntaxError.At("'search' directive must appear before other statements", t.Line, t.Col);
                    }
                    ParseSearchDirective();
                    continue;
                }
                if (Peek().Type == TokenType.RENDER)
                {
                    if (render != null)
                    {
                        Token t = Peek();
                        throw DslSyntaxError.At("Duplicate render() directive", t.Line, t.Col);
                    }
                    render = ParseRenderDirective();
                    while (Peek().Type == TokenType.SEMICOLON) Advance();
                    if (leadingComments.Count > 0 && render != null)
                        render.LeadingComments = leadingComments;
                    List<string> trailing = CollectComments();
                    if (trailing.Count > 0) trailingComments.AddRange(trailing);
                    break; // render TERMINATES program parse (reference/01 §3.1d)
                }
                Node stmt = ParseStatement();
                if (leadingComments.Count > 0 && stmt != null) stmt.LeadingComments = leadingComments;
                if (stmt is VarAssignNode va) vars.Add(va);
                else if (stmt != null) plans.Add(stmt);
                while (Peek().Type == TokenType.SEMICOLON) Advance();
            }

            Expect(TokenType.EOF, "Expected end of input");
            if (_programSearchOrder == null || _programSearchOrder.Count == 0)
                throw new DslSyntaxError("Missing required 'search' directive. Every program must start with 'search <namespace>, ...' to specify namespace search order.");

            var program = new ProgramNode
            {
                Plans = plans,
                Render = render,
                Vars = vars.Count > 0 ? vars : null,
                TrailingComments = trailingComments.Count > 0 ? trailingComments : null
            };

            // namespace meta (deep copy, reference/01 §6.1).
            var meta = new NamespaceMeta { SearchOrder = new List<string>(_programSearchOrder) };
            foreach (var imp in _programNamespace.Imports)
                meta.Imports.Add(new NamespaceImport { Name = imp.Name, Source = imp.Source, Explicit = imp.Explicit });
            if (_programNamespace.Default != null)
                meta.Default = new NamespaceImport
                {
                    Name = _programNamespace.Default.Name,
                    Source = _programNamespace.Default.Source,
                    Explicit = _programNamespace.Default.Explicit
                };
            program.Namespace = meta;
            return program;
        }

        private void ParseSearchDirective()
        {
            if (_programSearchOrder != null)
            {
                Token t = Peek();
                throw DslSyntaxError.At("Only one search directive is allowed per program", t.Line, t.Col);
            }
            Advance(); // consume 'search'
            var namespaces = new List<string>();

            Token first = Peek();
            if (!NamespaceTokens.Contains(first.Type))
                throw DslSyntaxError.At("Expected namespace identifier after search", first.Line, first.Col);
            Advance();
            ValidateNamespace(first);
            namespaces.Add(first.Lexeme);

            while (Peek().Type == TokenType.COMMA)
            {
                Advance();
                Token nsTok = Peek();
                if (!NamespaceTokens.Contains(nsTok.Type))
                    throw DslSyntaxError.At("Expected namespace identifier after comma", nsTok.Line, nsTok.Col);
                Advance();
                ValidateNamespace(nsTok);
                namespaces.Add(nsTok.Lexeme);
            }

            _programSearchOrder = namespaces;
            _programNamespace.Imports = new List<NamespaceImport>();
            foreach (string nm in namespaces)
                _programNamespace.Imports.Add(new NamespaceImport { Name = nm, Source = "search", Explicit = true });
            _programNamespace.Default = new NamespaceImport { Name = namespaces[0], Source = "search", Explicit = true };

            while (Peek().Type == TokenType.SEMICOLON) Advance();
        }

        private void ValidateNamespace(Token token)
        {
            string ns = token.Lexeme;
            if (_registry == null || !_registry.IsValidNamespace(ns))
            {
                string valid = "";
                if (_registry != null) valid = string.Join(", ", _registry.Namespaces);
                throw DslSyntaxError.At("Invalid namespace '" + ns + "'. Valid namespaces: " + valid, token.Line, token.Col);
            }
        }

        private OutputRefNode ParseRenderDirective()
        {
            Advance(); // consume 'render'
            Expect(TokenType.LPAREN, "Expect '('");
            if (Peek().Type != TokenType.OUTPUT_REF)
                throw new DslSyntaxError("Expected output reference in render()");
            var outRef = new OutputRefNode { Name = Advance().Lexeme };
            Expect(TokenType.RPAREN, "Expect ')'");
            return outRef;
        }

        // --- statements (reference/01 §3.3) ---------------------------------

        private List<Node> ParseBlock()
        {
            Expect(TokenType.LBRACE, "Expect '{'");
            var body = new List<Node>();
            while (Peek().Type != TokenType.RBRACE)
            {
                body.Add(ParseStatement());
                while (Peek().Type == TokenType.SEMICOLON) Advance();
            }
            Expect(TokenType.RBRACE, "Expect '}'");
            return body;
        }

        private Node ParseStatement()
        {
            if (Peek().Type == TokenType.SEARCH)
            {
                Token t = Peek();
                throw DslSyntaxError.At("'search' directive is only allowed at the start of the program", t.Line, t.Col);
            }
            if (Peek().Type == TokenType.LET)
            {
                Advance();
                string name = Expect(TokenType.IDENT, "Expected identifier").Lexeme;
                Expect(TokenType.EQUAL, "Expect '='");
                if (!ExprStart.Contains(Peek().Type))
                {
                    Token t = Peek();
                    throw DslSyntaxError.At("Expected expression after '='", t.Line, t.Col);
                }
                Node expr = ParseAdditive();
                return new VarAssignNode { Name = name, Expr = expr };
            }

            switch (Peek().Type)
            {
                case TokenType.IF:
                {
                    Advance();
                    Expect(TokenType.LPAREN, "Expect '('");
                    Node condition = ParseAdditive();
                    Expect(TokenType.RPAREN, "Expect ')'");
                    List<Node> then = ParseBlock();
                    var elif = new List<ElifClause>();
                    while (Peek().Type == TokenType.ELIF)
                    {
                        Advance();
                        Expect(TokenType.LPAREN, "Expect '('");
                        Node ec = ParseAdditive();
                        Expect(TokenType.RPAREN, "Expect ')'");
                        List<Node> body = ParseBlock();
                        elif.Add(new ElifClause { Condition = ec, Then = body });
                    }
                    List<Node> elseBranch = null;
                    if (Peek().Type == TokenType.ELSE)
                    {
                        Advance();
                        elseBranch = ParseBlock();
                    }
                    return new IfStmtNode { Condition = condition, Then = then, Elif = elif, Else = elseBranch };
                }
                case TokenType.BREAK: Advance(); return new BreakNode();
                case TokenType.CONTINUE: Advance(); return new ContinueNode();
                case TokenType.RETURN:
                {
                    Advance();
                    if (ExprStart.Contains(Peek().Type))
                        return new ReturnNode { Value = ParseAdditive() };
                    return new ReturnNode();
                }
            }

            List<Node> chain = ParseChain("statement");
            Node write = null;
            Write3DTarget write3d = null;
            if (chain.Count > 0)
            {
                Node last = chain[chain.Count - 1];
                if (last is WriteNode wn) write = wn.Surface;
                else if (last is Write3DNode w3 ) write3d = new Write3DTarget { Tex3d = w3.Tex3d, Geo = w3.Geo };
            }
            return new ChainStatementNode { Chain = chain, Write = write, Write3d = write3d };
        }

        // --- chains (reference/01 §4.1) -------------------------------------

        private List<Node> ParseChain(string context)
        {
            Node firstCall = ParseCall();
            var calls = new List<Node> { firstCall };
            while (true)
            {
                int savedPos = _current;
                List<string> leadingComments = CollectComments();
                if (Peek().Type != TokenType.DOT)
                {
                    _current = savedPos; // comments belong to next statement
                    break;
                }
                Advance(); // consume '.'
                List<string> postDot = CollectComments();
                var allComments = new List<string>(leadingComments);
                allComments.AddRange(postDot);

                TokenType nextType = Peek().Type;
                if (nextType == TokenType.WRITE || nextType == TokenType.WRITE3D)
                {
                    if (context == "expression")
                    {
                        Token t = Peek();
                        throw DslSyntaxError.At("'.write()' is only allowed in statement context", t.Line, t.Col);
                    }
                    Node writeNode = ParseWriteCall();
                    if (allComments.Count > 0) writeNode.LeadingComments = allComments;
                    calls.Add(writeNode);
                    continue;
                }
                if (nextType == TokenType.SUBCHAIN)
                {
                    Node subchainNode = ParseSubchainCall();
                    if (allComments.Count > 0) subchainNode.LeadingComments = allComments;
                    calls.Add(subchainNode);
                    continue;
                }
                Node call = ParseCall();
                if (allComments.Count > 0) call.LeadingComments = allComments;
                calls.Add(call);
            }
            return calls;
        }

        private Node ParseWriteCall()
        {
            TokenType tokenType = Peek().Type;
            int tokenLine = Peek().Line;
            int tokenCol = Peek().Col;

            if (tokenType == TokenType.WRITE)
            {
                Advance();
                Expect(TokenType.LPAREN, "Expect '('");
                Node surface;
                switch (Peek().Type)
                {
                    case TokenType.OUTPUT_REF: surface = new OutputRefNode { Name = Advance().Lexeme }; break;
                    case TokenType.XYZ_REF: surface = new SurfaceRefNode(NodeKind.XyzRef) { Name = Advance().Lexeme }; break;
                    case TokenType.VEL_REF: surface = new SurfaceRefNode(NodeKind.VelRef) { Name = Advance().Lexeme }; break;
                    case TokenType.RGBA_REF: surface = new SurfaceRefNode(NodeKind.RgbaRef) { Name = Advance().Lexeme }; break;
                    case TokenType.MESH_REF: surface = new SurfaceRefNode(NodeKind.MeshRef) { Name = Advance().Lexeme }; break;
                    default:
                        if (Peek().Type == TokenType.IDENT && Peek().Lexeme == "none")
                            surface = new OutputRefNode { Name = Advance().Lexeme };
                        else
                            throw DslSyntaxError.At("write() requires an explicit surface reference (e.g., o0, o1, xyz0, vel0, rgba0, mesh0, none)", Peek().Line, Peek().Col);
                        break;
                }
                Expect(TokenType.RPAREN, "Expect ')'");
                return new WriteNode { Surface = surface, LocLine = tokenLine, LocCol = tokenCol };
            }
            // WRITE3D
            Advance();
            Expect(TokenType.LPAREN, "Expect '('");
            Node tex3d;
            if (Peek().Type == TokenType.OUTPUT_REF) tex3d = new OutputRefNode { Name = Advance().Lexeme };
            else if (Peek().Type == TokenType.VOL_REF) tex3d = new SurfaceRefNode(NodeKind.VolRef) { Name = Advance().Lexeme };
            else if (Peek().Type == TokenType.IDENT) tex3d = new IdentNode { Name = Advance().Lexeme };
            else throw DslSyntaxError.At("Expected tex3d reference in write3d()", Peek().Line, Peek().Col);
            Expect(TokenType.COMMA, "Expect ',' between tex3d and geo in write3d()");
            Node geo;
            if (Peek().Type == TokenType.OUTPUT_REF) geo = new OutputRefNode { Name = Advance().Lexeme };
            else if (Peek().Type == TokenType.GEO_REF) geo = new SurfaceRefNode(NodeKind.GeoRef) { Name = Advance().Lexeme };
            else if (Peek().Type == TokenType.IDENT) geo = new IdentNode { Name = Advance().Lexeme };
            else throw DslSyntaxError.At("Expected geo reference in write3d()", Peek().Line, Peek().Col);
            Expect(TokenType.RPAREN, "Expect ')'");
            return new Write3DNode { Tex3d = tex3d, Geo = geo, LocLine = tokenLine, LocCol = tokenCol };
        }

        private Node ParseSubchainCall()
        {
            int tokenLine = Peek().Line;
            int tokenCol = Peek().Col;
            Advance(); // consume 'subchain'
            Expect(TokenType.LPAREN, "Expect '(' after subchain");

            string nameVal = null;
            string idVal = null;
            int? iterationsVal = null;
            if (Peek().Type != TokenType.RPAREN)
            {
                if (Peek().Type == TokenType.STRING)
                {
                    nameVal = Advance().Lexeme; // positional name
                }
                else if (Peek().Type == TokenType.IDENT && TokenAt(_current + 1)?.Type == TokenType.COLON)
                {
                    while (Peek().Type == TokenType.IDENT && TokenAt(_current + 1)?.Type == TokenType.COLON)
                    {
                        string key = Advance().Lexeme;
                        Advance(); // consume ':'
                        // DSL LOOPS: `iterations:` takes a NUMBER; name/id remain STRING
                        // (reference subchain only had name/id strings — this is additive
                        // and does not alter the string-arg path).
                        if (key == "iterations")
                        {
                            if (Peek().Type != TokenType.NUMBER)
                                throw DslSyntaxError.At("Expected number value for subchain iterations", Peek().Line, Peek().Col);
                            double n = double.Parse(Advance().Lexeme, System.Globalization.CultureInfo.InvariantCulture);
                            iterationsVal = (int)System.Math.Floor(n);
                            if (iterationsVal < 1) iterationsVal = 1;
                        }
                        else
                        {
                            if (Peek().Type != TokenType.STRING)
                                throw DslSyntaxError.At("Expected string value for subchain " + key, Peek().Line, Peek().Col);
                            string val = Advance().Lexeme;
                            if (key == "name") nameVal = val;
                            else if (key == "id") idVal = val;
                        }
                        if (Peek().Type == TokenType.COMMA) Advance();
                    }
                }
            }
            Expect(TokenType.RPAREN, "Expect ')' after subchain arguments");
            Expect(TokenType.LBRACE, "Expect '{' to start subchain body");

            var body = new List<Node>();
            while (Peek().Type != TokenType.RBRACE)
            {
                List<string> leadingComments = CollectComments();
                if (Peek().Type == TokenType.RBRACE) break;
                if (Peek().Type != TokenType.DOT)
                    throw DslSyntaxError.At("Expected '.' before chain element in subchain body", Peek().Line, Peek().Col);
                Advance(); // consume '.'
                List<string> postDot = CollectComments();
                var allComments = new List<string>(leadingComments);
                allComments.AddRange(postDot);
                Node call = ParseCall();
                if (allComments.Count > 0) call.LeadingComments = allComments;
                body.Add(call);
            }
            Expect(TokenType.RBRACE, "Expect '}' to end subchain body");
            if (body.Count == 0)
                throw DslSyntaxError.At("Subchain body cannot be empty", tokenLine, tokenCol);

            return new SubchainNode { Name = nameVal, Id = idVal, Iterations = iterationsVal, Body = body, LocLine = tokenLine, LocCol = tokenCol };
        }

        // --- calls (reference/01 §4.2) --------------------------------------

        private Node ParseCall()
        {
            Token nameToken = Expect(TokenType.IDENT, "Expected identifier");
            // Inline namespace `a.b()` forbidden (reference/01 §4.2.2).
            if (Peek().Type == TokenType.DOT)
            {
                Token next = TokenAt(_current + 1);
                if (next != null && next.Type == TokenType.IDENT)
                {
                    Token after = TokenAt(_current + 2);
                    if (after != null && after.Type == TokenType.LPAREN)
                        throw DslSyntaxError.At(
                            "Inline namespace syntax '" + nameToken.Lexeme + "." + next.Lexeme +
                            "()' is not allowed. Use 'search " + nameToken.Lexeme +
                            "' at the start of the program instead,", nameToken.Line, nameToken.Col);
                }
            }
            Expect(TokenType.LPAREN, "Expect '('");
            var args = new List<Node>();
            OrderedKwargs kwargs = null;
            bool keyword = false;
            if (Peek().Type != TokenType.RPAREN)
            {
                if (Peek().Type == TokenType.IDENT && TokenAt(_current + 1)?.Type == TokenType.COLON)
                {
                    keyword = true;
                    kwargs = new OrderedKwargs();
                    ParseKwarg(kwargs);
                    while (Peek().Type == TokenType.COMMA)
                    {
                        Advance();
                        if (Peek().Type == TokenType.RPAREN) break;
                        if (!(Peek().Type == TokenType.IDENT && TokenAt(_current + 1)?.Type == TokenType.COLON))
                        {
                            Token t = Peek();
                            throw DslSyntaxError.At("Cannot mix positional and keyword arguments", t.Line, t.Col);
                        }
                        ParseKwarg(kwargs);
                    }
                }
                else
                {
                    args.Add(ParseArg());
                    while (Peek().Type == TokenType.COMMA)
                    {
                        Advance();
                        if (Peek().Type == TokenType.RPAREN) break;
                        if (Peek().Type == TokenType.IDENT && TokenAt(_current + 1)?.Type == TokenType.COLON)
                        {
                            Token t = Peek();
                            throw DslSyntaxError.At("Cannot mix positional and keyword arguments", t.Line, t.Col);
                        }
                        args.Add(ParseArg());
                    }
                }
            }
            Expect(TokenType.RPAREN, "Expect ')'");

            var call = new CallNode { Name = nameToken.Lexeme, Args = args };
            if (keyword) call.Kwargs = kwargs;

            // Special-form transforms (reference/01 §4.2, in this order).
            if (nameToken.Lexeme == "from") return TransformFrom(call, nameToken);
            if (nameToken.Lexeme == "osc")
            {
                bool hasTypeKwarg = kwargs != null && kwargs.Has("type");
                bool firstArgIsOscKind = args.Count > 0 && args[0] is MemberNode m &&
                                         m.Path.Count > 0 && m.Path[0] == "oscKind";
                bool isBareOsc = args.Count == 0 && (kwargs == null || kwargs.Count == 0);
                bool hasOnlyOscKwargs = kwargs != null && kwargs.Count > 0 && AllOscKwargs(kwargs);
                if (hasTypeKwarg || firstArgIsOscKind || isBareOsc || hasOnlyOscKwargs)
                    return TransformOsc(call, nameToken);
                // else fall through: synth.osc generator effect
            }
            if (nameToken.Lexeme == "midi") return TransformMidi(call, nameToken);
            if (nameToken.Lexeme == "audio") return TransformAudio(call, nameToken);
            if (nameToken.Lexeme == "read")
            {
                Node surface = args.Count > 0 ? args[0]
                    : (kwargs != null ? (kwargs.Get("tex") ?? kwargs.Get("surface")) : null);
                var node = new ReadNode { Surface = surface, LocLine = nameToken.Line, LocCol = nameToken.Col };
                Node skip = kwargs?.Get("_skip");
                if (skip is BooleanNode sb && sb.Value) node.Skip = true;
                return node;
            }
            if (nameToken.Lexeme == "read3d")
            {
                Node tex3d = args.Count > 0 ? args[0] : (kwargs != null ? kwargs.Get("tex3d") : null);
                Node geo = args.Count > 1 ? args[1] : (kwargs != null ? kwargs.Get("geo") : null);
                var node = new Read3DNode { Tex3d = tex3d, Geo = geo, LocLine = nameToken.Line, LocCol = nameToken.Col };
                Node skip = kwargs?.Get("_skip");
                if (skip is BooleanNode sb && sb.Value) node.Skip = true;
                return node;
            }
            return call;
        }

        private static readonly HashSet<string> OscKwargKeys =
            new HashSet<string> { "type", "min", "max", "speed", "offset", "seed" };

        private static bool AllOscKwargs(OrderedKwargs kw)
        {
            foreach (string k in kw.Keys) if (!OscKwargKeys.Contains(k)) return false;
            return true;
        }

        private Node ParseArg() { return ParseAdditive(); }

        private void ParseKwarg(OrderedKwargs obj)
        {
            string key = Expect(TokenType.IDENT, "Expected identifier").Lexeme;
            Expect(TokenType.COLON, "Expect ':'");
            if (!ExprStart.Contains(Peek().Type))
            {
                Token t = Peek();
                throw DslSyntaxError.At("Expected expression after '='", t.Line, t.Col);
            }
            obj.Set(key, ParseArg());
        }

        // --- special-form transforms (reference/01 §4.6 / §7) ---------------

        private Node TransformFrom(CallNode call, Token nameToken)
        {
            void Fail(string message) { throw DslSyntaxError.At(message, nameToken.Line, nameToken.Col); }
            if (call.Kwargs != null && call.Kwargs.Count > 0) Fail("'from' does not support named arguments");
            if (call.Args.Count != 2) Fail("'from' requires exactly two arguments (namespace, call)");

            Node namespaceArg = call.Args[0];
            Node targetArg = call.Args[1];
            string namespaceName = null;
            if (namespaceArg is IdentNode idn) namespaceName = idn.Name;
            else if (namespaceArg is MemberNode mn) namespaceName = string.Join(".", mn.Path);
            else Fail("'from' namespace argument must be an identifier");
            if (string.IsNullOrEmpty(namespaceName)) Fail("'from' namespace argument must be non-empty");

            CallNode targetCall = null;
            if (targetArg is CallNode tc) targetCall = tc;
            else if (targetArg is ChainNode chn && chn.Chain.Count == 1 && chn.Chain[0] is CallNode hc) targetCall = hc;
            if (targetCall == null) Fail("'from' second argument must be a call expression");

            var replacement = new CallNode
            {
                Name = targetCall.Name,
                Args = new List<Node>(targetCall.Args)
            };
            if (targetCall.Kwargs != null)
            {
                var kw = new OrderedKwargs();
                foreach (string k in targetCall.Kwargs.Keys) kw.Set(k, targetCall.Kwargs.Get(k));
                replacement.Kwargs = kw;
            }
            replacement.Namespace = new NamespaceOverride
            {
                Name = namespaceName,
                Path = new List<string> { namespaceName },
                Explicit = true,
                Source = "from",
                Resolved = namespaceName,
                SearchOrder = new List<string> { namespaceName },
                FromOverride = true
            };
            return replacement;
        }

        private Node TransformOsc(CallNode call, Token nameToken)
        {
            string[] order = { "type", "min", "max", "speed", "offset", "seed" };
            if (call.Kwargs != null)
                foreach (string key in call.Kwargs.Keys)
                    if (!OscKwargKeys.Contains(key))
                        throw DslSyntaxError.At("osc() unknown parameter '" + key + "'. Valid: type, min, max, speed, offset, seed", nameToken.Line, nameToken.Col);

            Node Resolve(int i, Node dflt) { return ResolveParam(call, order[i], i, dflt); }
            Node typeNode = Resolve(0, MemberOf("oscKind", "sine"));
            return new OscillatorNode
            {
                OscType = typeNode,
                Min = Resolve(1, Num(0)),
                Max = Resolve(2, Num(1)),
                Speed = Resolve(3, Num(1)),
                Offset = Resolve(4, Num(0)),
                Seed = Resolve(5, Num(1)),
                LocLine = nameToken.Line, LocCol = nameToken.Col
            };
        }

        private Node TransformMidi(CallNode call, Token nameToken)
        {
            string[] order = { "channel", "mode", "min", "max", "sensitivity" };
            Node Resolve(int i, Node dflt) { return ResolveParam(call, order[i], i, dflt); }
            Node channel = Resolve(0, null);
            if (channel == null)
                throw DslSyntaxError.At("midi() requires 'channel' argument", nameToken.Line, nameToken.Col);
            return new MidiNode
            {
                Channel = channel,
                Mode = Resolve(1, MemberOf("midiMode", "velocity")),
                Min = Resolve(2, Num(0)),
                Max = Resolve(3, Num(1)),
                Sensitivity = Resolve(4, Num(1)),
                LocLine = nameToken.Line, LocCol = nameToken.Col
            };
        }

        private Node TransformAudio(CallNode call, Token nameToken)
        {
            string[] order = { "band", "min", "max" };
            Node Resolve(int i, Node dflt) { return ResolveParam(call, order[i], i, dflt); }
            Node band = Resolve(0, null);
            if (band == null)
                throw DslSyntaxError.At("audio() requires 'band' argument", nameToken.Line, nameToken.Col);
            return new AudioNode
            {
                Band = band,
                Min = Resolve(1, Num(0)),
                Max = Resolve(2, Num(1)),
                LocLine = nameToken.Line, LocCol = nameToken.Col
            };
        }

        // kwarg if present, else positional by index, else default (reference/01 §7).
        private static Node ResolveParam(CallNode call, string name, int index, Node dflt)
        {
            if (call.Kwargs != null && call.Kwargs.Has(name)) return call.Kwargs.Get(name);
            if (index < call.Args.Count) return call.Args[index];
            return dflt;
        }

        private static NumberNode Num(double v) { return new NumberNode { Value = v }; }
        private static MemberNode MemberOf(string a, string b)
        {
            return new MemberNode { Path = new List<string> { a, b } };
        }

        // --- expressions (reference/01 §4.4/§4.5) ---------------------------

        private Node ParseAdditive()
        {
            Node node = ParseMultiplicative();
            while (Peek().Type == TokenType.PLUS || Peek().Type == TokenType.MINUS)
            {
                TokenType op = Advance().Type;
                Node right = ParseMultiplicative();
                double l = ToNumber(node);
                double r = ToNumber(right);
                node = new NumberNode { Value = op == TokenType.PLUS ? l + r : l - r };
            }
            return node;
        }

        private Node ParseMultiplicative()
        {
            Node node = ParseUnary();
            while (Peek().Type == TokenType.STAR || Peek().Type == TokenType.SLASH)
            {
                TokenType op = Advance().Type;
                Node right = ParseUnary();
                double l = ToNumber(node);
                double r = ToNumber(right);
                node = new NumberNode { Value = op == TokenType.STAR ? l * r : l / r };
            }
            return node;
        }

        private Node ParseUnary()
        {
            if (Peek().Type == TokenType.PLUS) { Advance(); return ParseUnary(); }
            if (Peek().Type == TokenType.MINUS)
            {
                Advance();
                Node val = ParseUnary();
                return new NumberNode { Value = -ToNumber(val) };
            }
            return ParsePrimary();
        }

        private static double ToNumber(Node node)
        {
            if (node is NumberNode nn) return nn.Value;
            throw new DslSyntaxError("Expected number");
        }

        private Node ParsePrimary()
        {
            Token token = Peek();
            switch (token.Type)
            {
                case TokenType.NUMBER:
                    Advance();
                    return new NumberNode { Value = ParseFloatJs(token.Lexeme) };
                case TokenType.STRING:
                    Advance();
                    return new StringNode { Value = token.Lexeme };
                case TokenType.HEX:
                    Advance();
                    return ParseHex(token.Lexeme);
                case TokenType.LBRACKET:
                {
                    int sl = token.Line, sc = token.Col;
                    Advance();
                    var elements = new List<Node>();
                    if (Peek().Type != TokenType.RBRACKET)
                    {
                        elements.Add(ParseArg());
                        while (Peek().Type == TokenType.COMMA) { Advance(); elements.Add(ParseArg()); }
                    }
                    if (Peek().Type != TokenType.RBRACKET)
                    {
                        Token t = Peek();
                        throw DslSyntaxError.At("Expected ']'", t.Line, t.Col);
                    }
                    Advance();
                    return new ArrayLiteralNode { Elements = elements, LocLine = sl, LocCol = sc };
                }
                case TokenType.FUNC:
                    Advance();
                    return new FuncNode { Src = token.Lexeme };
                case TokenType.TRUE:
                    Advance();
                    return new BooleanNode { Value = true };
                case TokenType.FALSE:
                    Advance();
                    return new BooleanNode { Value = false };
                case TokenType.IDENT:
                {
                    // Math.PI
                    if (token.Lexeme == "Math" && TokenAt(_current + 1)?.Type == TokenType.DOT &&
                        TokenAt(_current + 2)?.Type == TokenType.IDENT && TokenAt(_current + 2).Lexeme == "PI")
                    {
                        Advance(); Advance(); Advance();
                        return new NumberNode { Value = 3.141592653589793 };
                    }
                    // member-then-call OR direct call -> parse as chain (expression context)
                    if (TokenAt(_current + 1)?.Type == TokenType.LPAREN || HasCallAfterDot(_current))
                    {
                        List<Node> chain = ParseChain("expression");
                        return chain.Count == 1 ? chain[0] : new ChainNode { Chain = chain };
                    }
                    // dotted member path
                    Advance();
                    var path = new List<string> { token.Lexeme };
                    while (Peek().Type == TokenType.DOT)
                    {
                        Token next = TokenAt(_current + 1);
                        if (next == null) break;
                        if (TokenAt(_current + 2)?.Type == TokenType.LPAREN) break; // dot begins a call
                        if (!MemberTokens.Contains(next.Type))
                            throw DslSyntaxError.At("Expected identifier after '.'", next.Line, next.Col);
                        Advance(); // consume '.'
                        Advance(); // consume segment
                        path.Add(next.Lexeme);
                    }
                    if (path.Count > 1) return new MemberNode { Path = path };
                    return new IdentNode { Name = path[0] };
                }
                case TokenType.OUTPUT_REF: Advance(); return new OutputRefNode { Name = token.Lexeme };
                case TokenType.SOURCE_REF: Advance(); return new SurfaceRefNode(NodeKind.SourceRef) { Name = token.Lexeme };
                case TokenType.VOL_REF: Advance(); return new SurfaceRefNode(NodeKind.VolRef) { Name = token.Lexeme };
                case TokenType.GEO_REF: Advance(); return new SurfaceRefNode(NodeKind.GeoRef) { Name = token.Lexeme };
                case TokenType.XYZ_REF: Advance(); return new SurfaceRefNode(NodeKind.XyzRef) { Name = token.Lexeme };
                case TokenType.VEL_REF: Advance(); return new SurfaceRefNode(NodeKind.VelRef) { Name = token.Lexeme };
                case TokenType.RGBA_REF: Advance(); return new SurfaceRefNode(NodeKind.RgbaRef) { Name = token.Lexeme };
                case TokenType.MESH_REF: Advance(); return new SurfaceRefNode(NodeKind.MeshRef) { Name = token.Lexeme };
                case TokenType.LPAREN:
                {
                    Advance();
                    Node expr = ParseAdditive();
                    Expect(TokenType.RPAREN, "Expect ')'");
                    return expr;
                }
                default:
                    throw DslSyntaxError.At("Unexpected token " + token.Type, token.Line, token.Col);
            }
        }

        private bool HasCallAfterDot(int index)
        {
            int i = index + 1;
            if (TokenAt(i)?.Type != TokenType.DOT) return false;
            while (TokenAt(i)?.Type == TokenType.DOT)
            {
                Token segToken = TokenAt(i + 1);
                if (segToken == null || !MemberTokens.Contains(segToken.Type)) return false;
                i += 2;
            }
            return TokenAt(i)?.Type == TokenType.LPAREN;
        }

        // HEX -> Color (reference/01 §5). parseInt(pair,16)/255 in double.
        private static ColorNode ParseHex(string lexeme)
        {
            string hex = lexeme.Substring(1);
            double r, g, b, a = 1.0;
            if (hex.Length == 3)
            {
                r = HexPair("" + hex[0] + hex[0]);
                g = HexPair("" + hex[1] + hex[1]);
                b = HexPair("" + hex[2] + hex[2]);
            }
            else if (hex.Length == 6)
            {
                r = HexPair(hex.Substring(0, 2));
                g = HexPair(hex.Substring(2, 2));
                b = HexPair(hex.Substring(4, 2));
            }
            else // length 8
            {
                r = HexPair(hex.Substring(0, 2));
                g = HexPair(hex.Substring(2, 2));
                b = HexPair(hex.Substring(4, 2));
                a = HexPair(hex.Substring(6, 2)) / 255.0;
            }
            return new ColorNode { Value = new[] { r / 255.0, g / 255.0, b / 255.0, a } };
        }

        private static int HexPair(string pair)
        {
            return System.Convert.ToInt32(pair, 16);
        }

        // JS parseFloat on a lexeme that has no sign/exponent. Numbers parse with the
        // invariant culture so a comma-decimal locale cannot corrupt them.
        private static double ParseFloatJs(string lexeme)
        {
            return double.Parse(lexeme,
                System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture);
        }
    }
}
