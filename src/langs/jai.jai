highlight_jai_syntax :: (using buffer: *Buffer) {
    tokenizer := get_tokenizer(buffer);

    clear_buffer_regions(buffer);
    start_scope(*tokenizer, 0, .scope_export);

    while true {
        token := get_next_token(*tokenizer);
        if token.type == .eof break;

        // Maybe retroactively highlight a function
        before_prev, prev := tokenizer.last_tokens[0], tokenizer.last_tokens[1];
        if token.type == .punctuation && token.punctuation == .l_paren {
            if prev.type == .identifier {
                // Handle "func("
                memset(colors.data + prev.start, xx Color.CODE_FUNCTION, prev.len);
            } else if before_prev.type == .identifier && prev.type == .operation && prev.operation == .double_colon {
                // Handle "func :: ("
                memset(colors.data + before_prev.start, xx Color.CODE_FUNCTION, before_prev.len);
            }
        } else if (token.type == .keyword && token.keyword == .kw_inline) || (token.type == .compiler_directive && token.compiler_directive == .directive_bake_arguments) {
            // Handle "func :: inline" and "func :: #bake_arguments"
            if before_prev.type == .identifier && prev.type == .operation && prev.operation == .double_colon {
                memset(colors.data + before_prev.start, xx Color.CODE_FUNCTION, before_prev.len);
            }
        }

        // Remember last 2 tokens
        tokenizer.last_tokens[0] = tokenizer.last_tokens[1];
        tokenizer.last_tokens[1] = token;

        color := COLOR_MAP[token.type];
        memset(colors.data + token.start, xx color, token.len);
    }

    end_scope(*tokenizer, bytes.count);
}

tokenize_jai_for_indentation :: (using buffer: *Buffer) -> [] Indentation_Token /* temp */ {
    tokens: [..] Indentation_Token;
    tokens.allocator = temp;

    tokenizer := get_tokenizer(buffer);

    while true {
        src := get_next_token(*tokenizer);

        tokenizer.last_tokens[0] = tokenizer.last_tokens[1];  // if we don't remember last 2 tokens, here strings won't be detected properly
        tokenizer.last_tokens[1] = src;

        token: Indentation_Token = ---;
        token.start = src.start;
        token.len   = src.len;

        if src.type == {
            case .punctuation;
                if src.punctuation == {
                    case .l_paren;      token.type = .open;  token.kind = .paren;
                    case .l_bracket;    token.type = .open;  token.kind = .bracket;
                    case .l_brace;      token.type = .open;  token.kind = .brace;

                    case .r_paren;      token.type = .close; token.kind = .paren;
                    case .r_bracket;    token.type = .close; token.kind = .bracket;
                    case .r_brace;      token.type = .close; token.kind = .brace;

                    case;               continue;
                }

            case .multiline_comment;    token.type = .maybe_multiline;
            case .here_string;          token.type = .maybe_multiline;
            case .eof;                  token.type = .eof;  // to guarantee we always have indentation tokens
            case;                       token.type = .unimportant;
        }

        array_add(*tokens, token);

        if src.type == .eof break;
    }

    return tokens;
}

#scope_file

// We're using a separate tokenizer here because we have to keep track of last 2 tokens in many places
// and we can't use a global variable for that because of threading
get_tokenizer :: (using buffer: *Buffer) -> Jai_Tokenizer {
    tokenizer: Jai_Tokenizer;

    tokenizer.buffer = buffer;
    tokenizer.buf    = cast(string) bytes;
    tokenizer.max_t  = bytes.data + bytes.count;
    tokenizer.t      = bytes.data;

    return tokenizer;
}

eat_white_space :: (using tokenizer: *Jai_Tokenizer) {
    while t < max_t && is_white_space(t.*) {
        t += 1;
    }
}

get_next_token :: (using tokenizer: *Jai_Tokenizer) -> Token {
    eat_white_space(tokenizer);

    token: Token;
    token.start = cast(s32) (t - buf.data);
    token.type  = .eof;
    if t >= max_t return token;

    start_t = t;

    // Assume ASCII, unless we're in the middle of a string.
    // UTF-8 characters elsewhere are a syntax error.
    char := << t;

    if is_alpha(char) || char == #char "_" {
        parse_identifier(tokenizer, *token);
    } else if is_digit(char) {
        // Handle number literals that don't look like they are being finished properly
        // For example, 0b10002 will highlight 0b1000 as one number and 2 as another number,
        // but when highlit in editor it looks like one number literal rather than two
        // The solution here is to not highlight more numbers if there are many number tokens in a row
        last_char := (t - 1).*;
        if tokenizer.last_tokens[1].type != .number || (!is_digit(last_char) && last_char != #char "_") {
            parse_number(tokenizer, *token);
        }
        else {
            parse_identifier(tokenizer, *token);
        }
    } else if char == {
        case #char ":";  parse_colon             (tokenizer, *token);
        case #char "=";  parse_equal             (tokenizer, *token);
        case #char "-";  parse_minus             (tokenizer, *token);
        case #char "+";  parse_plus              (tokenizer, *token);
        case #char "*";  parse_asterisk          (tokenizer, *token);
        case #char "<";  parse_less_than         (tokenizer, *token);
        case #char ">";  parse_greater_than      (tokenizer, *token);
        case #char "!";  parse_bang              (tokenizer, *token);
        case #char "#";  parse_compiler_directive(tokenizer, *token);
        case #char "\""; parse_string_literal    (tokenizer, *token);
        case #char "\t"; parse_tab               (tokenizer, *token);
        case #char "/";  parse_slash_or_comment  (tokenizer, *token);
        case #char "&";  parse_ampersand         (tokenizer, *token);
        case #char "|";  parse_pipe              (tokenizer, *token);
        case #char "%";  parse_percent           (tokenizer, *token);
        case #char "@";  parse_note              (tokenizer, *token);
        case #char "^";  parse_caret             (tokenizer, *token);
        case #char ".";  parse_period            (tokenizer, *token);

        case #char ";";  token.type = .punctuation; token.punctuation = .semicolon; t += 1;
        case #char ",";  token.type = .punctuation; token.punctuation = .comma;     t += 1;
        case #char "{";  token.type = .punctuation; token.punctuation = .l_brace;   t += 1;
        case #char "}";  token.type = .punctuation; token.punctuation = .r_brace;   t += 1;
        case #char "(";  token.type = .punctuation; token.punctuation = .l_paren;   t += 1;
        case #char ")";  token.type = .punctuation; token.punctuation = .r_paren;   t += 1;
        case #char "[";  token.type = .punctuation; token.punctuation = .l_bracket; t += 1;
        case #char "]";  token.type = .punctuation; token.punctuation = .r_bracket; t += 1;
        case #char "$";  token.type = .punctuation; token.punctuation = .dollar;    t += 1;

        case #char "~";  token.type = .operation;   token.operation   = .tilde;     t += 1;
        case #char "`";  token.type = .operation;   token.operation   = .backtick;  t += 1;

        case;            token.type = .invalid; t += 1;
    }

    if t >= max_t then t = max_t;
    token.len = cast(s32) (t - start_t);
    return token;
}

parse_identifier :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .identifier;

    auto_release_temp();

    identifier_str := read_identifier_string_tmp(tokenizer);

    // Maybe it's a keyword
    if identifier_str.count <= MAX_KEYWORD_LENGTH {
        kw_token, ok := table_find(*KEYWORD_MAP, identifier_str);
        if ok { token.type = kw_token.type; token.keyword = kw_token.keyword; return; }
    }

    // Check for here-string and directive modifiers
    prev, before_prev := last_tokens[1], last_tokens[0];
    if prev.type == .compiler_directive && prev.compiler_directive == .directive_string {
        token.type = .here_string;
        end := find_index_from_left(buf, identifier_str, start_index = t - buf.data);
        if end < 0 { t = max_t; return; }
        t = buf.data + end + identifier_str.count;
    } else if prev.type == .punctuation && prev.punctuation == .comma {
        is_modifier := false;
        if before_prev.type == {
            case .compiler_directive;
                if before_prev.compiler_directive == {
                    case .directive_type;           is_modifier = array_find(string.["isa", "distinct"], identifier_str);
                    case .directive_import;         is_modifier = array_find(string.["file", "dir", "string"], identifier_str);
                    case .directive_insert;         is_modifier = array_find(string.["scope"], identifier_str);
                    case .directive_run;            is_modifier = array_find(string.["stallable"], identifier_str);
                    case .directive_library;        is_modifier = array_find(string.["no_static_library", "no_dll", "system", "link_always"], identifier_str);
                    case .directive_system_library; is_modifier = array_find(string.["no_static_library", "no_dll", "link_always"], identifier_str);
                }
            case .keyword;
                if before_prev.keyword == {
                    case .kw_using;   is_modifier = array_find(string.["only", "except", "map"], identifier_str);
                    case .kw_cast;    is_modifier = array_find(string.["no_check", "trunc", "force"], identifier_str);
                }
        }
        if is_modifier then token.type = .modifier;
    }
}

parse_number :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .number;

    t += 1;
    if t >= max_t return;

    is_decimal_variant :: inline (c: u8) -> bool {
        return is_digit(c) || c == #char "." || c == #char "-" || c == #char "e" || c == #char "E";
    }

    if is_decimal_variant(t.*) || t.* == #char "_" {
        // Decimal
        seen_decimal_point  := false;
        scientific_notation := false;
        while t < max_t && (is_decimal_variant(t.*) || t.* == #char "_") {
            if t.* == #char "." {
                // Handle 0..1 (gets interpreted as a float-period-int rather than int-rangeop-int)
                if (t + 1) < max_t && (t + 1).* == #char "." {
                    break;
                }

                // else handle float decimal
                if seen_decimal_point then break;
                seen_decimal_point = true;
            }
            else if t.* == #char "e" || t.* == #char "E" {
                // Scientific notation (3.5e2, 1.0e-34)
                // Only works if there is a decimal point
                if scientific_notation || !seen_decimal_point then break;
                scientific_notation = true;
            }
            else if t.* == #char "-" {
                // Handle negative exponent in scientific notation (1.0e-34)
                if !scientific_notation then break;
                if (t - 1).* != #char "e" && (t - 1).* != #char "E" then break;
            }

            t += 1;
        }
    } else if t.* == #char "x" || t.* == #char "h" {
        // Hex
        t += 1;
        while t < max_t && (is_hex(t.*) || t.* == #char "_") t += 1;
    } else if t.* == #char "b" {
        // Binary
        t += 1;
        while t < max_t && (t.* == #char "1" || t.* == #char "0" || t.* == #char "_") t += 1;
    }
}

parse_compiler_directive :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .identifier;

    t += 1;
    eat_white_space(tokenizer);  // there may be spaces between the # and the name
    if t >= max_t return;
    if !is_alpha(<<t) return;

    start_offset := cast(s32) (start_t - buf.data);

    auto_release_temp();

    directive_str := read_identifier_string_tmp(tokenizer);

    // Check if it's one of the existing directives
    if directive_str.count > MAX_DIRECTIVE_LENGTH return;
    directive, ok := table_find(*COMPILER_DIRECTIVES_MAP, directive_str);
    if ok {
        token.type = .compiler_directive;
        token.compiler_directive = directive;

        if directive == {
            case .directive_scope_export;     start_scope(tokenizer, start_offset, .scope_export);
            case .directive_scope_module;     start_scope(tokenizer, start_offset, .scope_module);
            case .directive_scope_file;       start_scope(tokenizer, start_offset, .scope_file);
        }
    }
}

parse_colon :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .operation;
    token.operation = .colon;

    t += 1;
    if t >= max_t return;

    if << t == {
        case #char ":";  token.operation = .double_colon;  t += 1;
        case #char "=";  token.operation = .colon_equal;   t += 1;
    }
}

parse_equal :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .operation;
    token.operation = .equal;

    t += 1;
    if t >= max_t return;

    if << t == {
        case #char "=";  token.operation = .equal_equal; t += 1;
    }
}

parse_minus :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .operation;
    token.operation = .minus;

    t += 1;
    if t >= max_t return;

    if t.* == {
        case #char "=";
            token.operation = .minus_equal;
            t += 1;
        case #char ">";
            token.operation = .arrow;
            t += 1;
        case #char "-";
            t += 1;
            if t < max_t && << t == #char "-" {
                token.operation = .triple_dash;
                t += 1;
            } else {
                token.operation = .unknown;  // -- is not a valid token
            }
        case;
            if tokenizer.last_tokens[1].type != .number && is_digit(t.*) {
                parse_number(tokenizer, token);
            }
    }
}

parse_plus :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .operation;
    token.operation = .plus;

    t += 1;
    if t >= max_t return;

    if << t == {
        case #char "=";
            token.operation = .plus_equal;
            t += 1;
    }
}

parse_asterisk :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .operation;
    token.operation = .asterisk;

    t += 1;
    if t >= max_t return;

    if << t == {
        case #char "=";
            token.operation = .asterisk_equal;
            t += 1;
    }
}

parse_period :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type        = .punctuation;
    token.punctuation = .period;

    t += 1;
    if t >= max_t return;

    if t.* == {
        case #char ".";
            token.type      = .operation;
            token.operation = .double_period;
            t += 1;

        case #char "*";
            token.type      = .operation;
            token.operation = .period_asterisk;
            t += 1;
    }
}

parse_bang :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .operation;
    token.operation = .bang;

    t += 1;
    if t >= max_t return;

    if << t == {
        case #char "=";
            token.operation = .bang_equal;
            t += 1;
    }
}

parse_percent :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .operation;
    token.operation = .percent;

    t += 1;
    if t >= max_t return;

    if << t == {
        case #char "=";
            token.operation = .percent_equal;
            t += 1;
    }
}

parse_caret :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .operation;
    token.operation = .caret;

    t += 1;
    if t >= max_t return;

    if << t == {
        case #char "=";
            token.operation = .caret_equal;
            t += 1;
    }
}

parse_note :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .note;

    t += 1;
    while t < max_t && is_alnum(<< t) t += 1;
    if t >= max_t return;
}

parse_ampersand :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .operation;
    token.operation = .ampersand;

    t += 1;
    if t >= max_t return;

    if << t == {
        case #char "=";
            token.operation = .ampersand_equal;
            t += 1;
        case #char "&";
            token.operation = .double_ampersand;
            t += 1;
    }
}

parse_pipe :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .operation;
    token.operation = .pipe;

    t += 1;
    if t >= max_t return;

    if << t == {
        case #char "=";
            token.operation = .pipe_equal;
            t += 1;
        case #char "|";
            token.operation = .double_pipe;
            t += 1;
    }
}

parse_less_than :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .operation;
    token.operation = .less_than;

    t += 1;
    if t >= max_t return;

    if << t == {
        case #char "=";
            token.operation = .less_than_equal;
            t += 1;
        case #char "<";
            token.operation = .double_less_than;
            t += 1;
    }
}

parse_greater_than :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .operation;
    token.operation = .greater_than;

    t += 1;
    if t >= max_t return;

    if << t == {
        case #char "=";
            token.operation = .greater_than_equal;
            t += 1;
    }
}

parse_tab :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .comment;
    t += 1;
    while t < max_t && << t == #char "\t" t += 1;
}

parse_slash_or_comment :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .operation;
    token.operation = .slash;

    t += 1;
    if t >= max_t return;

    if << t == {
        case #char "=";
            token.operation = .slash_equal;
            t += 1;
        case #char "/";
            token.type = .comment;
            t += 1;
            while t < max_t && << t != #char "\n" t += 1;
        case #char "*";
            token.type = .multiline_comment;
            t += 1;
            num_open_comments := 0;
            while t + 1 < max_t {
                if << t == #char "*" && << (t + 1) == #char "/" {
                    if num_open_comments == 0 {
                        t += 2;
                        break;
                    } else {
                        num_open_comments -= 1;
                    }
                } else if << t == #char "/" && << (t + 1) == #char "*" {
                    num_open_comments += 1;
                    t += 1;
                }
                t += 1;
            }
    }
}

parse_string_literal :: (using tokenizer: *Jai_Tokenizer, token: *Token) {
    token.type = .string_literal;

    escape_seen := false;

    t += 1;
    while t < max_t && << t != #char "\n" {
        if <<t == #char "\"" && !escape_seen break;
        escape_seen = !escape_seen && <<t == #char "\\";
        t += 1;
    }
    if t >= max_t return;

    t += 1;
}

read_identifier_string_tmp :: (using tokenizer: *Jai_Tokenizer) -> string /* temp */ {
    identifier: [..] u8;
    identifier.allocator = temp;

    array_add(*identifier, <<t);

    t += 1;
    slash_mode := false;

    while t < max_t {
        c := <<t;
        if is_alnum(c)      { t += 1; slash_mode = false; array_add(*identifier, c); continue; }
        if c == #char "\\"  { t += 1; slash_mode = true;  continue; }
        if slash_mode && is_white_space(c) { t += 1; continue; }
        break;
    }
    if t >= max_t then t = max_t;

    return cast(string) identifier;
}

start_scope :: (using tokenizer: *Jai_Tokenizer, offset: s64, kind: Buffer_Region.Kind) {
    if current_scope_id >= 0 then end_scope(tokenizer, offset);
    current_scope_id = buffer.regions.count;

    region := Buffer_Region.{
        start = xx offset,
        end   = -1,
        kind  = kind,
    };
    array_add(*buffer.regions, region);
}

end_scope :: inline (using tokenizer: *Jai_Tokenizer, offset: s64) {
    buffer.regions[current_scope_id].end = xx offset;
}

Jai_Tokenizer :: struct {
    buffer:  *Buffer;
    current_scope_id := -1;

    buf:     string;
    max_t:   *u8;
    start_t: *u8;  // cursor when starting parsing new token
    t:       *u8;  // cursor

    last_tokens: [2] Token;
}

Token :: struct {
    start, len: s32;
    type: Type = .invalid;

    // Additional info to distinguish between keywords/punctuation
    union {
        keyword:            Keyword;
        punctuation:        Punctuation;
        operation:          Operation;
        compiler_directive: Compiler_Directive;
    }

    Type :: enum u16 {
        eof;

        identifier;
        string_literal;
        here_string;
        note;
        number;
        comment;
        multiline_comment;
        operation;
        punctuation;
        modifier_keyword;
        keyword;
        type_keyword;
        value_keyword;
        compiler_directive;
        modifier;
        invalid;
    }
}

// Must match the order of the types in the enum
COLOR_MAP :: Color.[
    .CODE_COMMENT,       // eof - obviously not used
    .CODE_DEFAULT,       // identifier
    .CODE_STRING,        // string_literal
    .CODE_STRING,        // here_string
    .CODE_OPERATION,     // note
    .CODE_VALUE,         // number
    .CODE_COMMENT,       // comment
    .CODE_COMMENT,       // multiline_comment
    .CODE_OPERATION,     // operation
    .CODE_PUNCTUATION,   // punctuation
    .CODE_KEYWORD,       // keyword
    .CODE_KEYWORD,       // modifier_keyword
    .CODE_TYPE,          // type_keyword
    .CODE_VALUE,         // value_keyword
    .CODE_KEYWORD,       // compiler_directive
    .CODE_KEYWORD,       // modifier
    .CODE_ERROR,         // invalid
];

PUNCTUATION :: string.[
    "dollar", "semicolon", "l_paren", "r_paren", "l_brace", "r_brace", "l_bracket", "r_bracket",
    "period", "comma",
];

OPERATIONS :: string.[
    "arrow", "bang", "backtick", "pipe", "double_pipe", "pipe_equal", "equal", "equal_equal", "bang_equal",
    "percent", "percent_equal", "less_than", "double_less_than", "less_than_equal", "greater_than", "greater_than_equal",
    "minus", "minus_equal", "triple_dash", "asterisk", "asterisk_equal", "colon", "colon_equal", "double_colon", "slash",
    "plus", "plus_equal", "slash_equal", "ampersand", "double_ampersand", "ampersand_equal", "tilde", "unknown",
    "caret", "caret_equal", "double_period", "period_asterisk",
];

KEYWORDS :: string.[
    "break", "case", "cast", "code_of", "continue", "defer", "else", "enum", "enum_flags", "for", "initializer_of",
    "if", "ifx", "is_constant", "inline", "push_context", "return", "size_of", "struct", "then", "type_info", "type_of",
    "union", "using", "while", "xx", "operator", "remove", "interface", "no_inline",
];

TYPE_KEYWORDS :: string.[
    "__reg", "bool", "float", "float32", "float64", "int", "reg", "s16", "s32", "s64", "s8", "string",
    "u16", "u32", "u64", "u8", "void", "v128", "Any", "Code", "Type",
];

VALUE_KEYWORDS :: string.[
    "context", "it", "it_index", "null", "true", "false", "temp",
];

COMPILER_DIRECTIVES :: string.[
    "add_context", "align", "as", "asm", "assert", "bake_arguments", "bake_constants", "bytes", "c_call", "caller_code",
    "caller_location", "char", "code", "compiler", "complete", "cpp_method", "cpp_return_type_is_non_pod", "deprecated",
    "dump", "dynamic_specialize", "elsewhere", "expand", "file", "filepath", "foreign", "library", "system_library",
    "if", "ifx", "import", "insert", "insert_internal", "intrinsic", "line", "load",
    "location", "modify", "module_parameters", "must", "no_abc", "no_aoc", "no_alias", "no_context", "no_padding", "no_reset",
    "place", "placeholder", "poke_name", "procedure_of_call", "program_export", "run", "runtime_support",
    "scope_export", "scope_file", "scope_module", "specified", "string", "symmetric", "this", "through", "type",
    "type_info_no_size_complaint", "type_info_none", "type_info_procedures_are_void_pointers",
    "compile_time", "no_debug", "procedure_name", "discard", "entry_point",
];

#insert -> string {
    b: String_Builder;
    init_string_builder(*b);

    define_enum :: (b: *String_Builder, enum_name: string, prefix: string, value_lists: [][] string) {
        print_to_builder(b, "% :: enum u16 {\n", enum_name);
        for values : value_lists {
            for v : values print_to_builder(b, "    %0%;\n", prefix, v);
        }
        print_to_builder(b, "}\n");
    }

    define_enum(*b, "Punctuation",        "",           .[PUNCTUATION]);
    define_enum(*b, "Operation",          "",           .[OPERATIONS]);
    define_enum(*b, "Keyword",            "kw_",        .[KEYWORDS, TYPE_KEYWORDS, VALUE_KEYWORDS]);
    define_enum(*b, "Compiler_Directive", "directive_", .[COMPILER_DIRECTIVES]);

    return builder_to_string(*b);
}

Keyword_Token :: struct {
    type: Token.Type;
    keyword: Keyword;
}

KEYWORD_MAP :: #run -> Table(string, Keyword_Token) {
    table: Table(string, Keyword_Token);
    size := 10 * (KEYWORDS.count + TYPE_KEYWORDS.count + VALUE_KEYWORDS.count);
    init(*table, size);

    #insert -> string {
        b: String_Builder;
        for KEYWORDS        append(*b, sprint("table_add(*table, \"%1\", Keyword_Token.{ type = .keyword,       keyword = .kw_%1 });\n", it));
        for TYPE_KEYWORDS   append(*b, sprint("table_add(*table, \"%1\", Keyword_Token.{ type = .type_keyword,  keyword = .kw_%1 });\n", it));
        for VALUE_KEYWORDS  append(*b, sprint("table_add(*table, \"%1\", Keyword_Token.{ type = .value_keyword, keyword = .kw_%1 });\n", it));
        return builder_to_string(*b);
    }

    return table;
}

COMPILER_DIRECTIVES_MAP :: #run -> Table(string, Compiler_Directive) {
    table: Table(string, Compiler_Directive);
    size := 2 * COMPILER_DIRECTIVES.count;
    init(*table, size);

    #insert -> string {
        b: String_Builder;
        init_string_builder(*b);
        for COMPILER_DIRECTIVES {
            print_to_builder(*b, "table_add(*table, \"%1\", .directive_%1);\n", it);
        }
        return builder_to_string(*b);
    }

    return table;
}

MAX_KEYWORD_LENGTH :: #run -> s32 {
    result: s64;
    for KEYWORDS       { if it.count > result then result = it.count; }
    for TYPE_KEYWORDS  { if it.count > result then result = it.count; }
    for VALUE_KEYWORDS { if it.count > result then result = it.count; }
    return xx result;
}

MAX_DIRECTIVE_LENGTH :: #run -> s32 {
    result: s64;
    for COMPILER_DIRECTIVES { if it.count > result then result = it.count; }
    return xx result;
}
