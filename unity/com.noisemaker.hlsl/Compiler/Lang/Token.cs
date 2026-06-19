// Token.cs — DSL token kinds + the token record produced by the Lexer.
//
// reference/01 §1.1: every token is { type, lexeme, line, col }.
//   - Type   : the token kind (see TokenType).
//   - Lexeme : the matched source substring; for STRING/FUNC it is the *content*
//              without delimiters / arrow head (the lexer strips those).
//   - Line   : 1-based line at token start.
//   - Col    : 1-based column at token start (per-UTF-16-code-unit; tabs = 1).
//
// Pure C#, no UnityEngine. TokenType mirrors the uppercase string token kinds the
// reference lexer emits (reference/01 §1.4).

namespace Noisemaker.Hlsl.Compiler
{
    public enum TokenType
    {
        // literals / identifiers
        NUMBER,
        STRING,
        HEX,
        FUNC,
        IDENT,

        // surface refs
        OUTPUT_REF,
        SOURCE_REF,
        VOL_REF,
        GEO_REF,
        XYZ_REF,
        VEL_REF,
        RGBA_REF,
        MESH_REF,

        // punctuation
        DOT,
        LPAREN,
        RPAREN,
        LBRACE,
        RBRACE,
        LBRACKET,
        RBRACKET,
        COMMA,
        COLON,
        EQUAL,
        SEMICOLON,
        PLUS,
        MINUS,
        STAR,
        SLASH,

        // keywords (RESERVED_KEYWORDS — reference/01 §1.3)
        LET,
        RENDER,
        WRITE,
        WRITE3D,
        TRUE,
        FALSE,
        IF,
        ELIF,
        ELSE,
        BREAK,
        CONTINUE,
        RETURN,
        SEARCH,
        SUBCHAIN,

        // trivia / end
        COMMENT,
        EOF
    }

    public sealed class Token
    {
        public TokenType Type { get; }
        public string Lexeme { get; }
        public int Line { get; }
        public int Col { get; }

        public Token(TokenType type, string lexeme, int line, int col)
        {
            Type = type;
            Lexeme = lexeme;
            Line = line;
            Col = col;
        }

        public override string ToString()
        {
            return Type + "('" + Lexeme + "' @" + Line + ":" + Col + ")";
        }
    }
}
