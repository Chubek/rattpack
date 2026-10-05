 # Chapter 12: Case Study - Building an ANSI C Parser
 
 ## 12.1 Overview
 
 This chapter demonstrates building a complete ANSI C parser using LibGLR, covering all aspects of the library: grammar definition, lexical analysis, parsing, disambiguation, rewriting, and incremental parsing.
 
 ## 12.2 ANSI C Grammar
 
 ### 12.2.1 Grammar Structure
 
 ANSI C has several syntactic categories:
 
 - **Expressions**: literals, operators, function calls
 - **Declarations**: variables, functions, types
 - **Statements**: control flow, compound statements
 - **Preprocessing**: directives (handled separately)
 
 ### 12.2.2 Grammar File (c.grammar)
 
 ```
 %token IDENTIFIER CONSTANT STRING_LITERAL
 %token SIZEOF
 %token PTR_OP INC_OP DEC_OP LEFT_OP RIGHT_OP LE_OP GE_OP EQ_OP NE_OP
 %token AND_OP OR_OP MUL_ASSIGN DIV_ASSIGN MOD_ASSIGN ADD_ASSIGN
 %token SUB_ASSIGN LEFT_ASSIGN RIGHT_ASSIGN AND_ASSIGN
 %token XOR_ASSIGN OR_ASSIGN TYPE_NAME
 
 %token TYPEDEF EXTERN STATIC AUTO REGISTER
 %token CHAR SHORT INT LONG SIGNED UNSIGNED FLOAT DOUBLE CONST VOLATILE VOID
 %token STRUCT UNION ENUM ELLIPSIS
 
 %token CASE DEFAULT IF ELSE SWITCH WHILE DO FOR GOTO CONTINUE BREAK RETURN
 
 %start translation_unit
 
 %%
 
 primary_expression
     : IDENTIFIER
     | CONSTANT
     | STRING_LITERAL
     | '(' expression ')'
     ;
 
 postfix_expression
     : primary_expression
     | postfix_expression '[' expression ']'
     | postfix_expression '(' ')'
     | postfix_expression '(' argument_expression_list ')'
     | postfix_expression '.' IDENTIFIER
     | postfix_expression PTR_OP IDENTIFIER
     | postfix_expression INC_OP
     | postfix_expression DEC_OP
     ;
 
 unary_expression
     : postfix_expression
     | INC_OP unary_expression
     | DEC_OP unary_expression
     | unary_operator cast_expression
     | SIZEOF unary_expression
     | SIZEOF '(' type_name ')'
     ;
 
 unary_operator
     : '&'
     | '*'
     | '+'
     | '-'
     | '~'
     | '!'
     ;
 
 cast_expression
     : unary_expression
     | '(' type_name ')' cast_expression
     ;
 
 multiplicative_expression
     : cast_expression
     | multiplicative_expression '*' cast_expression
     | multiplicative_expression '/' cast_expression
     | multiplicative_expression '%' cast_expression
     ;
 
 additive_expression
     : multiplicative_expression
     | additive_expression '+' multiplicative_expression
     | additive_expression '-' multiplicative_expression
     ;
 
 shift_expression
     : additive_expression
     | shift_expression LEFT_OP additive_expression
     | shift_expression RIGHT_OP additive_expression
     ;
 
 relational_expression
     : shift_expression
     | relational_expression '<' shift_expression
     | relational_expression '>' shift_expression
     | relational_expression LE_OP shift_expression
     | relational_expression GE_OP shift_expression
     ;
 
 equality_expression
     : relational_expression
     | equality_expression EQ_OP relational_expression
     | equality_expression NE_OP relational_expression
     ;
 
 and_expression
     : equality_expression
     | and_expression '&' equality_expression
     ;
 
 exclusive_or_expression
     : and_expression
     | exclusive_or_expression '^' and_expression
     ;
 
 inclusive_or_expression
     : exclusive_or_expression
     | inclusive_or_expression '|' exclusive_or_expression
     ;
 
 logical_and_expression
     : inclusive_or_expression
     | logical_and_expression AND_OP inclusive_or_expression
     ;
 
 logical_or_expression
     : logical_and_expression
     | logical_or_expression OR_OP logical_and_expression
     ;
 
 conditional_expression
     : logical_or_expression
     | logical_or_expression '?' expression ':' conditional_expression
     ;
 
 assignment_expression
     : conditional_expression
     | unary_expression assignment_operator assignment_expression
     ;
 
 assignment_operator
     : '='
     | MUL_ASSIGN
     | DIV_ASSIGN
     | MOD_ASSIGN
     | ADD_ASSIGN
     | SUB_ASSIGN
     | LEFT_ASSIGN
     | RIGHT_ASSIGN
     | AND_ASSIGN
     | XOR_ASSIGN
     | OR_ASSIGN
     ;
 
 expression
     : assignment_expression
     | expression ',' assignment_expression
     ;
 
 declaration
     : declaration_specifiers ';'
     | declaration_specifiers init_declarator_list ';'
     ;
 
 declaration_specifiers
     : storage_class_specifier
     | storage_class_specifier declaration_specifiers
     | type_specifier
     | type_specifier declaration_specifiers
     | type_qualifier
     | type_qualifier declaration_specifiers
     ;
 
 storage_class_specifier
     : TYPEDEF
     | EXTERN
     | STATIC
     | AUTO
     | REGISTER
     ;
 
 type_specifier
     : VOID
     | CHAR
     | SHORT
     | INT
     | LONG
     | FLOAT
     | DOUBLE
     | SIGNED
     | UNSIGNED
     | struct_or_union_specifier
     | enum_specifier
     | TYPE_NAME
     ;
 
 struct_or_union_specifier
     : struct_or_union IDENTIFIER '{' struct_declaration_list '}'
     | struct_or_union '{' struct_declaration_list '}'
     | struct_or_union IDENTIFIER
     ;
 
 struct_or_union
     : STRUCT
     | UNION
     ;
 
 statement
     : labeled_statement
     | compound_statement
     | expression_statement
     | selection_statement
     | iteration_statement
     | jump_statement
     ;
 
 compound_statement
     : '{' '}'
     | '{' statement_list '}'
     | '{' declaration_list '}'
     | '{' declaration_list statement_list '}'
     ;
 
 selection_statement
     : IF '(' expression ')' statement
     | IF '(' expression ')' statement ELSE statement
     | SWITCH '(' expression ')' statement
     ;
 
 iteration_statement
     : WHILE '(' expression ')' statement
     | DO statement WHILE '(' expression ')' ';'
     | FOR '(' expression_statement expression_statement ')' statement
     | FOR '(' expression_statement expression_statement expression ')' statement
     ;
 
 translation_unit
     : external_declaration
     | translation_unit external_declaration
     ;
 
 external_declaration
     : function_definition
     | declaration
     ;
 
 function_definition
     : declaration_specifiers declarator declaration_list compound_statement
     | declaration_specifiers declarator compound_statement
     | declarator declaration_list compound_statement
     | declarator compound_statement
     ;
 ```
 
 ## 12.3 C Lexer Implementation
 
 ### 12.3.1 Token Types
 
 ```c
 typedef enum {
     TOKEN_IDENTIFIER,
     TOKEN_CONSTANT,
     TOKEN_STRING_LITERAL,
     TOKEN_SIZEOF,
     TOKEN_PTR_OP,      // ->
     TOKEN_INC_OP,      // ++
     TOKEN_DEC_OP,      // --
     TOKEN_LEFT_OP,     // <<
     TOKEN_RIGHT_OP,    // >>
     TOKEN_LE_OP,       // <=
     TOKEN_GE_OP,       // >=
     TOKEN_EQ_OP,       // ==
     TOKEN_NE_OP,       // !=
     TOKEN_AND_OP,      // &&
     TOKEN_OR_OP,       // ||
     // ... more tokens
 } c_token_type_t;
 ```
 
 ### 12.3.2 Lexer State
 
 ```c
 typedef struct {
     const char *input;
     size_t pos;
     size_t length;
     int line;
     int column;
     // Symbol table for typedef names
     hash_table_t *typedefs;
 } c_lexer_t;
 ```
 
 ### 12.3.3 Lexer Implementation
 
 ```c
 glr_reader_token_t c_lexer_next_token(c_lexer_t *lexer) {
     glr_reader_token_t token = {0};
     
     // Skip whitespace and comments
     skip_whitespace_and_comments(lexer);
     
     if (lexer->pos >= lexer->length) {
         token.terminal_name = strdup("EOF");
         return token;
     }
     
     token.byte_offset = lexer->pos;
     char c = lexer->input[lexer->pos];
     
     // Identifiers and keywords
     if (isalpha(c) || c == '_') {
         return lex_identifier_or_keyword(lexer);
     }
     
     // Numbers
     if (isdigit(c)) {
         return lex_number(lexer);
     }
     
     // String literals
     if (c == '"') {
         return lex_string_literal(lexer);
     }
     
     // Character constants
     if (c == '\'') {
         return lex_char_constant(lexer);
     }
     
     // Operators and punctuation
     return lex_operator(lexer);
 }
 
 glr_reader_token_t lex_identifier_or_keyword(c_lexer_t *lexer) {
     size_t start = lexer->pos;
     
     while (lexer->pos < lexer->length && 
            (isalnum(lexer->input[lexer->pos]) || lexer->input[lexer->pos] == '_')) {
         lexer->pos++;
     }
     
     size_t len = lexer->pos - start;
     char *word = strndup(lexer->input + start, len);
     
     glr_reader_token_t token = {0};
     token.byte_offset = start;
     token.bytes_consumed = len;
     
     // Check for keywords
     if (strcmp(word, "int") == 0) {
         token.terminal_name = strdup("INT");
     } else if (strcmp(word, "char") == 0) {
         token.terminal_name = strdup("CHAR");
     } else if (strcmp(word, "if") == 0) {
         token.terminal_name = strdup("IF");
     } else if (strcmp(word, "else") == 0) {
         token.terminal_name = strdup("ELSE");
     } else if (strcmp(word, "while") == 0) {
         token.terminal_name = strdup("WHILE");
     } else if (strcmp(word, "return") == 0) {
         token.terminal_name = strdup("RETURN");
     } else if (strcmp(word, "sizeof") == 0) {
         token.terminal_name = strdup("SIZEOF");
     }
     // Check if it's a typedef name
     else if (hash_table_contains(lexer->typedefs, word)) {
         token.terminal_name = strdup("TYPE_NAME");
     }
     // Otherwise it's an identifier
     else {
         token.terminal_name = strdup("IDENTIFIER");
     }
     
     free(word);
     return token;
 }
 
 glr_reader_token_t lex_operator(c_lexer_t *lexer) {
     glr_reader_token_t token = {0};
     token.byte_offset = lexer->pos;
     
     char c = lexer->input[lexer->pos];
     char next = (lexer->pos + 1 < lexer->length) ? lexer->input[lexer->pos + 1] : '\0';
     
     // Two-character operators
     if (c == '-' && next == '>') {
         token.terminal_name = strdup("PTR_OP");
         token.bytes_consumed = 2;
         lexer->pos += 2;
     } else if (c == '+' && next == '+') {
         token.terminal_name = strdup("INC_OP");
         token.bytes_consumed = 2;
         lexer->pos += 2;
     } else if (c == '-' && next == '-') {
         token.terminal_name = strdup("DEC_OP");
         token.bytes_consumed = 2;
         lexer->pos += 2;
     } else if (c == '<' && next == '<') {
         token.terminal_name = strdup("LEFT_OP");
         token.bytes_consumed = 2;
         lexer->pos += 2;
     } else if (c == '>' && next == '>') {
         token.terminal_name = strdup("RIGHT_OP");
         token.bytes_consumed = 2;
         lexer->pos += 2;
     } else if (c == '<' && next == '=') {
         token.terminal_name = strdup("LE_OP");
         token.bytes_consumed = 2;
         lexer->pos += 2;
     } else if (c == '>' && next == '=') {
         token.terminal_name = strdup("GE_OP");
         token.bytes_consumed = 2;
         lexer->pos += 2;
     } else if (c == '=' && next == '=') {
         token.terminal_name = strdup("EQ_OP");
         token.bytes_consumed = 2;
         lexer->pos += 2;
     } else if (c == '!' && next == '=') {
         token.terminal_name = strdup("NE_OP");
         token.bytes_consumed = 2;
         lexer->pos += 2;
     } else if (c == '&' && next == '&') {
         token.terminal_name = strdup("AND_OP");
         token.bytes_consumed = 2;
         lexer->pos += 2;
     } else if (c == '|' && next == '|') {
         token.terminal_name = strdup("OR_OP");
         token.bytes_consumed = 2;
         lexer->pos += 2;
     }
     // Single-character operators
     else {
         char op[2] = {c, '\0'};
         token.terminal_name = strdup(op);
         token.bytes_consumed = 1;
         lexer->pos++;
     }
     
     return token;
 }
 ```
 
 ## 12.4 Disambiguation for C
 
 ### 12.4.1 The Typedef Ambiguity
 
 C has a famous ambiguity: `(x) * y` can be:
 - A cast: `(type) * pointer`
 - Multiplication: `(expression) * expression`
 
 Resolution requires a symbol table to track typedef names.
 
 ### 12.4.2 Typedef Disambiguation Hook
 
 ```c
 typedef struct {
     hash_table_t *typedefs;
 } typedef_context_t;
 
 glr_disambig_result_t typedef_disambig(
     glr_disambig_context_t *context,
     size_t *winner_index,
     void *user_data
 ) {
     typedef_context_t *ctx = (typedef_context_t *)user_data;
     
     for (size_t i = 0; i < context->candidate_count; i++) {
         if (context->candidates[i].rejected) continue;
         
         glr_production_t *prod = context->candidates[i].production;
         
         // Check if this is a cast production
         if (is_cast_production(prod)) {
             // Check if the type name is in the typedef table
             const char *type_name = get_type_name_from_production(prod);
             if (hash_table_contains(ctx->typedefs, type_name)) {
                 *winner_index = i;
                 return GLR_DISAMBIG_RESOLVED;
             }
         }
     }
     
     return GLR_DISAMBIG_NO_MATCH;
 }
 ```
 
 ### 12.4.3 Dangling Else Disambiguation
 
 ```c
 glr_disambig_result_t dangling_else_disambig(
     glr_disambig_context_t *context,
     size_t *winner_index,
     void *user_data
 ) {
     // Prefer associating else with nearest if
     for (size_t i = 0; i < context->candidate_count; i++) {
         if (context->candidates[i].rejected) continue;
         
         if (is_nested_if_else(context->candidates[i].production)) {
             *winner_index = i;
             return GLR_DISAMBIG_RESOLVED;
         }
     }
     
     return GLR_DISAMBIG_NO_MATCH;
 }
 ```
 
 ## 12.5 Complete C Parser
 
 ### 12.5.1 Main Parser Implementation
 
 ```c
 #include <glr/glr.h>
 
 typedef struct {
     glr_grammar_t *grammar;
     glr_parser_t *parser;
     c_lexer_t *lexer;
     hash_table_t *typedefs;
     glr_cache_t *cache;
 } c_parser_t;
 
 c_parser_t *c_parser_create(void) {
     c_parser_t *parser = malloc(sizeof(c_parser_t));
     
     // Load C grammar
     parser->grammar = glr_grammar_load("c.grammar");
     
     // Generate parse table
     glr_parse_table_t *table = generate_lr_table(parser->grammar);
     glr_grammar_set_parse_table(parser->grammar, table, true);
     
     // Create parser
     parser->parser = glr_parser_create(parser->grammar);
     
     // Create lexer
     parser->lexer = c_lexer_create();
     
     // Create typedef table
     parser->typedefs = hash_table_create();
     
     // Create cache for incremental parsing
     parser->cache = glr_cache_create(1024);
     glr_parser_set_cache(parser->parser, parser->cache);
     
     // Register disambiguation hooks
     typedef_context_t *typedef_ctx = malloc(sizeof(typedef_context_t));
     typedef_ctx->typedefs = parser->typedefs;
     
     glr_disambig_hook_t *typedef_hook = glr_disambig_hook_create(
         "typedef",
         100,
         typedef_disambig,
         typedef_ctx,
         free
     );
     glr_parser_add_disambig_hook(parser->parser, typedef_hook);
     
     glr_disambig_hook_t *else_hook = glr_disambig_hook_create(
         "dangling_else",
         90,
         dangling_else_disambig,
         NULL,
         NULL
     );
     glr_parser_add_disambig_hook(parser->parser, else_hook);
     
     // Add standard disambiguation
     glr_parser_add_disambig_hook(parser->parser, glr_disambig_precedence_create());
     glr_parser_add_disambig_hook(parser->parser, glr_disambig_associativity_create());
     
     return parser;
 }
 
 glr_parse_result_t c_parser_parse_file(c_parser_t *parser, const char *filename) {
     // Read file
     FILE *fp = fopen(filename, "r");
     fseek(fp, 0, SEEK_END);
     size_t length = ftell(fp);
     fseek(fp, 0, SEEK_SET);
     char *input = malloc(length + 1);
     fread(input, 1, length, fp);
     input[length] = '\0';
     fclose(fp);
     
     // Set up lexer
     c_lexer_set_input(parser->lexer, input, length);
     
     // Create reader from lexer
     glr_reader_t *reader = glr_reader_create_from_callback(
         (glr_token_callback_t)c_lexer_next_token,
         parser->lexer
     );
     
     // Parse
     glr_parse_result_t result = glr_parse(parser->parser, input, length);
     
     // Extract typedefs from parse tree
     if (result.error == GLR_PARSE_SUCCESS) {
         extract_typedefs(result.forest, parser->typedefs);
     }
     
     // Cleanup
     glr_reader_destroy(reader);
     free(input);
     
     return result;
 }
 
 void c_parser_destroy(c_parser_t *parser) {
     glr_cache_destroy(parser->cache);
     hash_table_destroy(parser->typedefs);
     c_lexer_destroy(parser->lexer);
     glr_parser_destroy(parser->parser);
     glr_grammar_destroy(parser->grammar);
     free(parser);
 }
 ```
 
 ### 12.5.2 Usage Example
 
 ```c
 int main(int argc, char **argv) {
     if (argc != 2) {
         fprintf(stderr, "Usage: %s <file.c>\n", argv[0]);
         return 1;
     }
     
     // Create parser
     c_parser_t *parser = c_parser_create();
     
     // Parse file
     glr_parse_result_t result = c_parser_parse_file(parser, argv[1]);
     
     if (result.error == GLR_PARSE_SUCCESS) {
         printf("Parse successful!\n");
         printf("Forest has %zu nodes\n", result.forest->node_count);
         
         // Check for ambiguities
         size_t tree_count = count_parse_trees(result.forest);
         if (tree_count > 1) {
             printf("Warning: %zu parse trees (ambiguous)\n", tree_count);
         }
         
         // Extract AST
         glr_tree_t *ast = glr_disambiguate(result.forest, GLR_DISAMBIG_PRECEDENCE);
         
         // Process AST
         process_ast(ast);
         
         glr_tree_destroy(ast);
     } else {
         fprintf(stderr, "Parse failed at position %zu\n", result.position);
     }
     
     // Cleanup
     c_parser_destroy(parser);
     
     return 0;
 }
 ```
 
 ## 12.6 Testing the Parser
 
 ### 12.6.1 Test Cases
 
 ```c
 void test_c_parser(void) {
     c_parser_t *parser = c_parser_create();
     
     // Test 1: Simple declaration
     test_parse(parser, "int x;", "simple_declaration");
     
     // Test 2: Function definition
     test_parse(parser, "int main(void) { return 0; }", "function_definition");
     
     // Test 3: Typedef
     test_parse(parser, "typedef int myint; myint x;", "typedef");
     
     // Test 4: Cast vs multiplication
     test_parse(parser, "(int) * p;", "cast");
     test_parse(parser, "(x) * y;", "multiplication");
     
     // Test 5: Dangling else
     test_parse(parser, "if (a) if (b) x = 1; else x = 2;", "dangling_else");
     
     c_parser_destroy(parser);
 }
 
 void test_parse(c_parser_t *parser, const char *input, const char *test_name) {
     printf("Testing: %s\n", test_name);
     
     c_lexer_set_input(parser->lexer, input, strlen(input));
     glr_parse_result_t result = glr_parse(parser->parser, input, strlen(input));
     
     if (result.error == GLR_PARSE_SUCCESS) {
         printf("  ✓ Parse successful\n");
     } else {
         printf("  ✗ Parse failed at position %zu\n", result.position);
     }
 }
 ```
 
 ## 12.7 Summary
 
 This case study demonstrated:
 
 - Building a complete ANSI C grammar
 - Implementing a C lexer with keyword recognition
 - Handling typedef ambiguity with semantic disambiguation
 - Resolving dangling else with precedence rules
 - Creating a reusable C parser with caching
 - Testing the parser with various C constructs
 
 The techniques shown here apply to any programming language:
 
 1. Define the grammar
 2. Implement the lexer
 3. Generate parse tables
 4. Add disambiguation hooks
 5. Test thoroughly
 6. Optimize with caching and rewriting
 
 LibGLR provides all the tools needed to build production-quality parsers for complex, ambiguous languages.
