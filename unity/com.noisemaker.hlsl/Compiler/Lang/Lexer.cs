// Lexer.cs — DSL tokenizer, a 1:1 port of shaders/src/lang/lexer.js (reference/01 §1).
//
// PARITY-CRITICAL details replicated exactly:
//  - 1-based line/col; col counts UTF-16 code units (C# char == JS UTF-16 unit);
//    tabs count as 1; '\n' resets col=1, line++ (reference/01 §1.2).
//  - Rule order is load-bearing (reference/01 §1.4): comments, surface-prefix refs
//    (o/s, vol, geo, xyz, vel BEFORE testing — note vol tested before vel by 3rd
//    char; rgba/mesh need 4 prefix chars + digit), hex {3,6,8} only, arrow FUNC,
//    leading-dot number, single-char punctuation, triple-quote string, single/double
//    string (escapes NOT decoded), number, identifier/keyword, else throw.
//  - HEX gated to total length 4/7/9 (i.e. 3/6/8 hex digits); otherwise '#' falls
//    through to the final throw.
//  - String escapes are NOT decoded: lexeme is the raw inter-delimiter text.
//
// Pure C#, no UnityEngine. Throws DslSyntaxError (mirrors JS SyntaxError text).

using System.Collections.Generic;

namespace Noisemaker.Hlsl.Compiler
{
    public static class Lexer
    {
        // RESERVED_KEYWORDS (reference/01 §1.3 / lexer.js RESERVED_KEYWORDS, frozen).
        private static readonly Dictionary<string, TokenType> Keywords =
            new Dictionary<string, TokenType>
            {
                { "let", TokenType.LET },
                { "render", TokenType.RENDER },
                { "write", TokenType.WRITE },
                { "write3d", TokenType.WRITE3D },
                { "true", TokenType.TRUE },
                { "false", TokenType.FALSE },
                { "if", TokenType.IF },
                { "elif", TokenType.ELIF },
                { "else", TokenType.ELSE },
                { "break", TokenType.BREAK },
                { "continue", TokenType.CONTINUE },
                { "return", TokenType.RETURN },
                { "search", TokenType.SEARCH },
                { "subchain", TokenType.SUBCHAIN },
            };

        private static bool IsDigit(char c) { return c >= '0' && c <= '9'; }
        private static bool IsLetter(char c)
        {
            return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        }
        private static bool IsHex(char c)
        {
            return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        }

        public static List<Token> Lex(string src)
        {
            var tokens = new List<Token>();
            if (src == null) src = "";
            int i = 0;
            int line = 1;
            int col = 1;
            int n = src.Length;

            // Bounds-safe char fetch (JS src[k] returns undefined past end; here a NUL
            // sentinel that never matches any real test).
            char At(int k) { return (k >= 0 && k < n) ? src[k] : '\0'; }

            while (i < n)
            {
                char ch = src[i];

                if (ch == ' ' || ch == '\t' || ch == '\r') { i++; col++; continue; }
                if (ch == '\n') { i++; line++; col = 1; continue; }

                int startLine = line;
                int startCol = col;

                // 2. line comment //...
                if (ch == '/' && At(i + 1) == '/')
                {
                    int j = i + 2;
                    while (j < n && src[j] != '\n') j++;
                    tokens.Add(new Token(TokenType.COMMENT, src.Substring(i, j - i), startLine, startCol));
                    col += j - i;
                    i = j;
                    continue;
                }

                // 3. block comment /* ... */
                if (ch == '/' && At(i + 1) == '*')
                {
                    int j = i + 2;
                    int endLine = line;
                    int endCol = col + 2;
                    while (j < n && !(src[j] == '*' && At(j + 1) == '/'))
                    {
                        if (src[j] == '\n') { endLine++; endCol = 1; }
                        else { endCol++; }
                        j++;
                    }
                    if (j >= n)
                        throw DslSyntaxError.At("Unterminated comment", startLine, startCol);
                    j += 2;
                    tokens.Add(new Token(TokenType.COMMENT, src.Substring(i, j - i), startLine, startCol));
                    line = endLine;
                    col = endCol + 2;
                    i = j;
                    continue;
                }

                // 4. output or source reference (o/s + digit)
                if ((ch == 'o' || ch == 's') && IsDigit(At(i + 1)))
                {
                    int j = i + 1;
                    while (j < n && IsDigit(src[j])) j++;
                    TokenType t = ch == 'o' ? TokenType.OUTPUT_REF : TokenType.SOURCE_REF;
                    tokens.Add(new Token(t, src.Substring(i, j - i), startLine, startCol));
                    col += j - i;
                    i = j;
                    continue;
                }

                // 5. vol reference (vol + digit) — tested BEFORE vel (rule 8)
                if (ch == 'v' && At(i + 1) == 'o' && At(i + 2) == 'l' && IsDigit(At(i + 3)))
                {
                    int j = i + 3;
                    while (j < n && IsDigit(src[j])) j++;
                    tokens.Add(new Token(TokenType.VOL_REF, src.Substring(i, j - i), startLine, startCol));
                    col += j - i;
                    i = j;
                    continue;
                }

                // 6. geo reference (geo + digit)
                if (ch == 'g' && At(i + 1) == 'e' && At(i + 2) == 'o' && IsDigit(At(i + 3)))
                {
                    int j = i + 3;
                    while (j < n && IsDigit(src[j])) j++;
                    tokens.Add(new Token(TokenType.GEO_REF, src.Substring(i, j - i), startLine, startCol));
                    col += j - i;
                    i = j;
                    continue;
                }

                // 7. xyz reference (xyz + digit)
                if (ch == 'x' && At(i + 1) == 'y' && At(i + 2) == 'z' && IsDigit(At(i + 3)))
                {
                    int j = i + 3;
                    while (j < n && IsDigit(src[j])) j++;
                    tokens.Add(new Token(TokenType.XYZ_REF, src.Substring(i, j - i), startLine, startCol));
                    col += j - i;
                    i = j;
                    continue;
                }

                // 8. vel reference (vel + digit) — v disambiguated from vol by 3rd char
                if (ch == 'v' && At(i + 1) == 'e' && At(i + 2) == 'l' && IsDigit(At(i + 3)))
                {
                    int j = i + 3;
                    while (j < n && IsDigit(src[j])) j++;
                    tokens.Add(new Token(TokenType.VEL_REF, src.Substring(i, j - i), startLine, startCol));
                    col += j - i;
                    i = j;
                    continue;
                }

                // 9. rgba reference (rgba + digit)
                if (ch == 'r' && At(i + 1) == 'g' && At(i + 2) == 'b' && At(i + 3) == 'a' && IsDigit(At(i + 4)))
                {
                    int j = i + 4;
                    while (j < n && IsDigit(src[j])) j++;
                    tokens.Add(new Token(TokenType.RGBA_REF, src.Substring(i, j - i), startLine, startCol));
                    col += j - i;
                    i = j;
                    continue;
                }

                // 10. mesh reference (mesh + digit)
                if (ch == 'm' && At(i + 1) == 'e' && At(i + 2) == 's' && At(i + 3) == 'h' && IsDigit(At(i + 4)))
                {
                    int j = i + 4;
                    while (j < n && IsDigit(src[j])) j++;
                    tokens.Add(new Token(TokenType.MESH_REF, src.Substring(i, j - i), startLine, startCol));
                    col += j - i;
                    i = j;
                    continue;
                }

                // 11. hex color literal (#); only emit for length 4/7/9
                if (ch == '#')
                {
                    int j = i + 1;
                    while (j < n && IsHex(src[j])) j++;
                    int len = j - i;
                    if (len == 4 || len == 7 || len == 9)
                    {
                        tokens.Add(new Token(TokenType.HEX, src.Substring(i, len), startLine, startCol));
                        col += len;
                        i = j;
                        continue;
                    }
                    // else fall through (no later rule matches '#' -> final throw)
                }

                // 12. arrow function () => expr
                if (ch == '(' && At(i + 1) == ')')
                {
                    int j = i + 2;
                    while (j < n && (src[j] == ' ' || src[j] == '\t')) j++;
                    if (At(j) == '=' && At(j + 1) == '>')
                    {
                        j += 2;
                        while (j < n && (src[j] == ' ' || src[j] == '\t')) j++;
                        int depth = 0;
                        int exprStart = j;
                        while (j < n)
                        {
                            char c = src[j];
                            if (c == '(') depth++;
                            else if (c == ')')
                            {
                                if (depth == 0) break;
                                depth--;
                            }
                            else if (depth == 0)
                            {
                                if (c == ',' || c == ';' || c == '\n' || c == '}') break;
                            }
                            j++;
                        }
                        string expr = src.Substring(exprStart, j - exprStart).Trim();
                        tokens.Add(new Token(TokenType.FUNC, expr, startLine, startCol));
                        col += j - i;
                        i = j;
                        continue;
                    }
                    // else fall through: '(' handled by single-char punctuation below
                }

                // 13. leading-dot number .D
                if (ch == '.' && IsDigit(At(i + 1)))
                {
                    int j = i + 1;
                    while (j < n && IsDigit(src[j])) j++;
                    tokens.Add(new Token(TokenType.NUMBER, src.Substring(i, j - i), startLine, startCol));
                    col += j - i;
                    i = j;
                    continue;
                }

                // 14. single-char punctuation
                if (TrySingleChar(ch, out TokenType punct))
                {
                    tokens.Add(new Token(punct, ch.ToString(), startLine, startCol));
                    i++;
                    col++;
                    continue;
                }

                // 15. triple-quoted string """ ... """ (checked before single quotes)
                if (ch == '"' && At(i + 1) == '"' && At(i + 2) == '"')
                {
                    int j = i + 3;
                    while (j < n - 2)
                    {
                        if (src[j] == '"' && src[j + 1] == '"' && src[j + 2] == '"') break;
                        if (src[j] == '\n') { line++; col = 0; }
                        j++;
                    }
                    if (j >= n - 2 || !(At(j) == '"' && At(j + 1) == '"' && At(j + 2) == '"'))
                        throw DslSyntaxError.At("Unterminated triple-quoted string", startLine, startCol);
                    string content = src.Substring(i + 3, j - (i + 3));
                    tokens.Add(new Token(TokenType.STRING, content, startLine, startCol));
                    // multi-line col fixup (reference/01 §1.4 rule 15)
                    string[] lines = content.Split('\n');
                    if (lines.Length > 1)
                        col = lines[lines.Length - 1].Length + 4;
                    else
                        col += j - i + 3;
                    i = j + 3;
                    continue;
                }

                // 16. single/double quoted string (escapes consume 2 chars, NOT decoded)
                if (ch == '"' || ch == '\'')
                {
                    char quote = ch;
                    int j = i + 1;
                    while (j < n && src[j] != quote && src[j] != '\n')
                    {
                        if (src[j] == '\\' && j + 1 < n) j += 2;
                        else j++;
                    }
                    if (j >= n || src[j] == '\n')
                        throw DslSyntaxError.At("Unterminated string literal", line, col);
                    string content = src.Substring(i + 1, j - (i + 1));
                    tokens.Add(new Token(TokenType.STRING, content, startLine, startCol));
                    col += j - i + 1;
                    i = j + 1;
                    continue;
                }

                // 17. number D...
                if (IsDigit(ch))
                {
                    int j = i;
                    while (j < n && IsDigit(src[j])) j++;
                    if (At(j) == '.' && IsDigit(At(j + 1)))
                    {
                        j++;
                        while (j < n && IsDigit(src[j])) j++;
                    }
                    tokens.Add(new Token(TokenType.NUMBER, src.Substring(i, j - i), startLine, startCol));
                    col += j - i;
                    i = j;
                    continue;
                }

                // 18. identifier / keyword
                if (IsLetter(ch) || ch == '_')
                {
                    int j = i;
                    while (j < n && (IsLetter(src[j]) || IsDigit(src[j]) || src[j] == '_')) j++;
                    string lexeme = src.Substring(i, j - i);
                    TokenType kw;
                    if (Keywords.TryGetValue(lexeme, out kw))
                        tokens.Add(new Token(kw, lexeme, startLine, startCol));
                    else
                        tokens.Add(new Token(TokenType.IDENT, lexeme, startLine, startCol));
                    col += j - i;
                    i = j;
                    continue;
                }

                // 19. anything else
                throw DslSyntaxError.At("Unexpected character '" + ch + "'", line, col);
            }

            tokens.Add(new Token(TokenType.EOF, "", line, col));
            return tokens;
        }

        private static bool TrySingleChar(char ch, out TokenType t)
        {
            switch (ch)
            {
                case '.': t = TokenType.DOT; return true;
                case '(': t = TokenType.LPAREN; return true;
                case ')': t = TokenType.RPAREN; return true;
                case '{': t = TokenType.LBRACE; return true;
                case '}': t = TokenType.RBRACE; return true;
                case '[': t = TokenType.LBRACKET; return true;
                case ']': t = TokenType.RBRACKET; return true;
                case ',': t = TokenType.COMMA; return true;
                case ':': t = TokenType.COLON; return true;
                case '=': t = TokenType.EQUAL; return true;
                case ';': t = TokenType.SEMICOLON; return true;
                case '+': t = TokenType.PLUS; return true;
                case '-': t = TokenType.MINUS; return true;
                case '*': t = TokenType.STAR; return true;
                case '/': t = TokenType.SLASH; return true;
                default: t = TokenType.EOF; return false;
            }
        }
    }
}
