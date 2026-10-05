 # Chapter 11: Advanced Topics and Integration
 
 ## 11.1 Overview
 
 This chapter covers advanced LibGLR usage including LSP integration, syntax highlighting, error recovery, and performance optimization.
 
 ## 11.2 Language Server Protocol (LSP) Integration
 
 ### 11.2.1 LSP Architecture
 
 ```c
 typedef struct {
     glr_parser_t *parser;
     glr_cache_t *cache;
     glr_forest_t *current_forest;
     char *document_uri;
     char *document_text;
     size_t document_length;
 } lsp_document_t;
 
 typedef struct {
     glr_grammar_t *grammar;
     lsp_document_t **documents;
     size_t document_count;
 } lsp_server_t;
 ```
 
 ### 11.2.2 Handling Document Changes
 
 ```c
 void lsp_handle_did_change(lsp_document_t *doc, 
                            size_t start, 
                            size_t old_length,
                            const char *new_text,
                            size_t new_length) {
     // Create diff
     glr_diff_edit_t edit = {
         .start = start,
         .old_length = old_length,
         .new_length = new_length,
         .new_text = new_text
     };
     
     // Incremental reparse
     glr_forest_t *new_forest = glr_parse_incremental(
         doc->parser,
         doc->current_forest,
         &edit
     );
     
     // Update document
     glr_forest_destroy(doc->current_forest);
     doc->current_forest = new_forest;
     
     // Update text
     update_document_text(doc, &edit);
 }
 ```
 
 ### 11.2.3 Providing Diagnostics
 
 ```c
 void lsp_provide_diagnostics(lsp_document_t *doc) {
     // Check for parse errors
     if (doc->current_forest == NULL) {
         lsp_diagnostic_t diag = {
             .severity = LSP_DIAGNOSTIC_ERROR,
             .message = "Syntax error",
             .range = {doc->parser->error_position, doc->parser->error_position + 1}
         };
         lsp_send_diagnostic(doc->document_uri, &diag);
     }
     
     // Check for ambiguities
     size_t tree_count = count_parse_trees(doc->current_forest);
     if (tree_count > 1) {
         lsp_diagnostic_t diag = {
             .severity = LSP_DIAGNOSTIC_WARNING,
             .message = "Ambiguous parse",
             .range = {0, doc->document_length}
         };
         lsp_send_diagnostic(doc->document_uri, &diag);
     }
 }
 ```
 
 ## 11.3 Syntax Highlighting for Terminal Pagers
 
 ### 11.3.1 ANSI Escape Codes
 
 ```c
 const char *ANSI_RESET = "\033[0m";
 const char *ANSI_KEYWORD = "\033[1;34m";  // Bold blue
 const char *ANSI_STRING = "\033[0;32m";   // Green
 const char *ANSI_COMMENT = "\033[0;90m";  // Gray
 const char *ANSI_NUMBER = "\033[0;33m";   // Yellow
 ```
 
 ### 11.3.2 Highlighting from Parse Tree
 
 ```c
 void highlight_tree(glr_forest_node_t *node, const char *input, FILE *output) {
     if (node->type == GLR_NODE_TERMINAL) {
         const char *color = get_color_for_token(node->symbol_id);
         fprintf(output, "%s%.*s%s", 
                 color,
                 (int)node->data_length,
                 input + node->position,
                 ANSI_RESET);
     } else {
         for (size_t i = 0; i < node->child_count; i++) {
             highlight_tree(node->children[i], input, output);
         }
     }
 }
 
 const char *get_color_for_token(int token_type) {
     switch (token_type) {
         case TOKEN_KEYWORD: return ANSI_KEYWORD;
         case TOKEN_STRING: return ANSI_STRING;
         case TOKEN_COMMENT: return ANSI_COMMENT;
         case TOKEN_NUMBER: return ANSI_NUMBER;
         default: return ANSI_RESET;
     }
 }
 ```
 
 ### 11.3.3 Complete Syntax Highlighter
 
 ```c
 #include <glr/glr.h>
 
 int main(int argc, char **argv) {
     if (argc != 2) {
         fprintf(stderr, "Usage: %s <file>\n", argv[0]);
         return 1;
     }
     
     // Load grammar
     glr_grammar_t *grammar = glr_grammar_load("c.grammar");
     glr_parser_t *parser = glr_parser_create(grammar);
     
     // Read file
     FILE *fp = fopen(argv[1], "r");
     fseek(fp, 0, SEEK_END);
     size_t length = ftell(fp);
     fseek(fp, 0, SEEK_SET);
     char *input = malloc(length + 1);
     fread(input, 1, length, fp);
     input[length] = '\0';
     fclose(fp);
     
     // Parse
     glr_parse_result_t result = glr_parse(parser, input, length);
     
     if (result.error == GLR_PARSE_SUCCESS) {
         // Disambiguate
         glr_tree_t *tree = glr_disambiguate(result.forest, GLR_DISAMBIG_PRECEDENCE);
         
         // Highlight
         highlight_tree(tree->root, input, stdout);
     } else {
         fprintf(stderr, "Parse error at position %zu\n", result.position);
     }
     
     // Cleanup
     free(input);
     glr_parser_destroy(parser);
     glr_grammar_destroy(grammar);
     
     return 0;
 }
 ```
 
 ## 11.4 Error Recovery
 
 ### 11.4.1 Panic Mode Recovery
 
 ```c
 glr_parse_result_t parse_with_recovery(glr_parser_t *parser, 
                                        const char *input, 
                                        size_t length) {
     glr_parse_result_t result = glr_parse(parser, input, length);
     
     if (result.error == GLR_PARSE_ERROR_SYNTAX) {
         // Skip to next synchronization point
         size_t pos = result.position;
         while (pos < length && !is_sync_token(input[pos])) {
             pos++;
         }
         
         if (pos < length) {
             // Try parsing from sync point
             glr_parser_reset(parser);
             result = glr_parse(parser, input + pos, length - pos);
             result.position += pos;
         }
     }
     
     return result;
 }
 
 bool is_sync_token(char c) {
     return c == ';' || c == '}' || c == '\n';
 }
 ```
 
 ### 11.4.2 Error Production Recovery
 
 Add error productions to the grammar:
 
 ```
 stmt : expr SEMICOLON
      | error SEMICOLON  /* Error recovery */
      ;
 ```
 
 ## 11.5 Performance Optimization
 
 ### 11.5.1 Profiling
 
 ```c
 typedef struct {
     uint64_t parse_time_ns;
     uint64_t disambiguation_time_ns;
     size_t max_stack_count;
     size_t max_forest_nodes;
 } glr_profile_t;
 
 glr_profile_t profile_parse(glr_parser_t *parser, 
                             const char *input, 
                             size_t length) {
     glr_profile_t profile = {0};
     
     uint64_t start = get_time_ns();
     glr_parse_result_t result = glr_parse(parser, input, length);
     profile.parse_time_ns = get_time_ns() - start;
     
     profile.max_stack_count = parser->max_stack_count;
     profile.max_forest_nodes = result.forest->node_count;
     
     start = get_time_ns();
     glr_disambiguate(result.forest, GLR_DISAMBIG_PRECEDENCE);
     profile.disambiguation_time_ns = get_time_ns() - start;
     
     return profile;
 }
 ```
 
 ### 11.5.2 Optimization Strategies
 
 - **Grammar optimization**: Use rewrite rules to reduce ambiguity
 - **Caching**: Enable parse result caching for incremental parsing
 - **Pruning**: Use disambiguation hooks to prune unlikely alternatives early
 - **Memory pooling**: Allocate nodes from memory pools instead of malloc
 - **Lazy evaluation**: Defer tree extraction until needed
 
 ## 11.6 Multi-threaded Parsing
 
 ```c
 typedef struct {
     glr_parser_t *parser;
     const char *input;
     size_t length;
     glr_parse_result_t result;
 } parse_job_t;
 
 void *parse_thread(void *arg) {
     parse_job_t *job = (parse_job_t *)arg;
     job->result = glr_parse(job->parser, job->input, job->length);
     return NULL;
 }
 
 // Parse multiple files in parallel
 void parse_files_parallel(const char **files, size_t file_count) {
     pthread_t *threads = malloc(file_count * sizeof(pthread_t));
     parse_job_t *jobs = malloc(file_count * sizeof(parse_job_t));
     
     for (size_t i = 0; i < file_count; i++) {
         jobs[i].parser = glr_parser_create(grammar);
         jobs[i].input = read_file(files[i], &jobs[i].length);
         pthread_create(&threads[i], NULL, parse_thread, &jobs[i]);
     }
     
     for (size_t i = 0; i < file_count; i++) {
         pthread_join(threads[i], NULL);
         process_result(&jobs[i].result);
     }
     
     free(threads);
     free(jobs);
 }
 ```
 
 ## 11.7 Summary
 
 - LSP integration enables IDE features
 - Syntax highlighting uses parse trees and ANSI codes
 - Error recovery improves robustness
 - Profiling identifies performance bottlenecks
 - Multi-threading enables parallel parsing
