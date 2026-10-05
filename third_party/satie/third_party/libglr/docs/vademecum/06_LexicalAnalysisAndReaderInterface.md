 # Chapter 6: Lexical Analysis and Reader Interface
 
 ## 6.1 Overview
 
 The reader interface (`include/glr/reader.h`) provides token stream abstraction for the parser. It handles:
 
 - UTF-16 input decoding
 - Token generation from input
 - Custom lexer integration via hooks
 - Position tracking for error reporting
 
 ## 6.2 Reader Structure
 
 ```c
 typedef struct glr_reader glr_reader_t;
 
 typedef struct {
     char *terminal_name;     // Heap-owned terminal name
     uint32_t codepoint;      // First Unicode scalar value
     size_t byte_offset;      // Byte offset in input buffer
     size_t bytes_consumed;   // Number of bytes consumed
     bool from_hook;          // True when from lexer hook
 } glr_reader_token_t;
 ```
 
 ## 6.3 Basic Reader Usage
 
 ```c
 #include <glr/reader.h>
 
 // Create reader
 glr_reader_t *reader = glr_reader_create();
 
 // Set input
 const char *input = "int x = 42;";
 glr_reader_set_input(reader, input, strlen(input));
 
 // Read tokens
 glr_reader_token_t token;
 while (glr_reader_next(reader, &token) == GLR_READER_STATUS_OK) {
     printf("Token: %s at offset %zu\n", token.terminal_name, token.byte_offset);
     glr_reader_token_clear(&token); // Free terminal_name
 }
 
 // Cleanup
 glr_reader_destroy(reader);
 ```
 
 ## 6.4 Lexer Hooks
 
 Custom lexers can be integrated via hooks (`include/glr/lexer-hooks.h`):
 
 ```c
 typedef struct glr_lexer_hooks glr_lexer_hooks_t;
 
 typedef struct {
     bool (*on_token)(glr_lexer_hooks_t *hooks, 
                      uint32_t codepoint, 
                      glr_reader_token_t *token);
     void *user_data;
 } glr_lexer_hooks_t;
 ```
 
 ### 6.4.1 Implementing a Custom Lexer
 
 ```c
 typedef struct {
     const char *input;
     size_t pos;
 } my_lexer_t;
 
 bool my_lexer_on_token(glr_lexer_hooks_t *hooks, 
                        uint32_t codepoint, 
                        glr_reader_token_t *token) {
     my_lexer_t *lexer = (my_lexer_t *)hooks->user_data;
     
     // Skip whitespace
     while (lexer->input[lexer->pos] == ' ' || 
            lexer->input[lexer->pos] == '\t') {
         lexer->pos++;
     }
     
     char c = lexer->input[lexer->pos];
     
     if (c == '\0') {
         return false; // EOF
     }
     
     token->byte_offset = lexer->pos;
     
     // Recognize keywords and identifiers
     if (isalpha(c)) {
         size_t start = lexer->pos;
         while (isalnum(lexer->input[lexer->pos])) {
             lexer->pos++;
         }
         
         size_t len = lexer->pos - start;
         char *word = strndup(lexer->input + start, len);
         
         // Check for keywords
         if (strcmp(word, "int") == 0) {
             token->terminal_name = strdup("INT");
         } else if (strcmp(word, "if") == 0) {
             token->terminal_name = strdup("IF");
         } else {
             token->terminal_name = strdup("IDENTIFIER");
         }
         
         free(word);
         token->bytes_consumed = len;
         token->from_hook = true;
         return true;
     }
     
     // Recognize numbers
     if (isdigit(c)) {
         size_t start = lexer->pos;
         while (isdigit(lexer->input[lexer->pos])) {
             lexer->pos++;
         }
         
         token->terminal_name = strdup("NUMBER");
         token->bytes_consumed = lexer->pos - start;
         token->from_hook = true;
         return true;
     }
     
     // Single-character tokens
     lexer->pos++;
     token->bytes_consumed = 1;
     token->from_hook = true;
     
     switch (c) {
         case '=': token->terminal_name = strdup("EQUALS"); break;
         case ';': token->terminal_name = strdup("SEMICOLON"); break;
         case '+': token->terminal_name = strdup("PLUS"); break;
         default: token->terminal_name = strdup("UNKNOWN"); break;
     }
     
     return true;
 }
 
 // Usage
 my_lexer_t lexer = { .input = "int x = 42;", .pos = 0 };
 glr_lexer_hooks_t hooks = {
     .on_token = my_lexer_on_token,
     .user_data = &lexer
 };
 
 glr_reader_set_lexer_hooks(reader, &hooks);
 ```
 
 ## 6.5 Token Callback Interface
 
 For simpler cases, use a token callback:
 
 ```c
 typedef glr_reader_token_t (*glr_token_callback_t)(void *user_data);
 
 glr_reader_token_t my_next_token(void *user_data) {
     my_lexer_t *lexer = (my_lexer_t *)user_data;
     glr_reader_token_t token = {0};
     
     // Generate next token
     // ...
     
     return token;
 }
 
 glr_reader_t *reader = glr_reader_create_from_callback(my_next_token, &lexer);
 ```
 
 ## 6.6 Position Tracking
 
 The reader tracks byte offsets for error reporting:
 
 ```c
 glr_reader_token_t token;
 glr_reader_status_t status = glr_reader_next(reader, &token);
 
 if (status == GLR_READER_STATUS_INVALID_SEQUENCE) {
     fprintf(stderr, "Invalid UTF-16 sequence at byte %zu\n", 
             glr_reader_get_position(reader));
 }
 ```
 
 ## 6.7 Summary
 
 - The reader provides token stream abstraction
 - Supports UTF-16 input with automatic encoding detection
 - Custom lexers integrate via hooks or callbacks
 - Tracks positions for error reporting
