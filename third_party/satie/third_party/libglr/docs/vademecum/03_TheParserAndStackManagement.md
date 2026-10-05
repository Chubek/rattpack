 # Chapter 3: The Parser and Stack Management
 
 ## 3.1 Overview
 
 The parser is the heart of LibGLR, orchestrating the interaction between the grammar, stack, and forest to implement the GLR algorithm. This chapter explores:
 
 - The parser structure and lifecycle
 - The GLR parsing algorithm
 - Stack management and forking
 - Handling shift-reduce and reduce-reduce conflicts
 - Error handling and recovery
 
 ## 3.2 Parser Structure
 
 ### 3.2.1 The Parser Object
 
 The `glr_parser_t` structure is defined in `include/glr/parser.h`:
 
 ```c
 struct glr_parser {
     glr_grammar_t *grammar;              // Grammar specification
     glr_stack_t **stacks;                // Array of active parse stacks (GSS)
     size_t stack_count;                  // Number of currently active stacks
     size_t stack_capacity;               // Allocated capacity for stacks array
     glr_forest_t *forest;                // Shared Packed Parse Forest (SPPF)
     void **state_table;                  // LR state transition table
     size_t state_table_size;             // Number of states in table
     glr_parse_table_t *parse_table;      // Optional typed parse table override
     bool owns_parse_table;               // Whether parser destroys parse_table
     glr_disambig_hook_t *disambig_hooks; // Chain of disambiguation hooks
     const char *input;                   // Current input buffer
     size_t input_pos;                    // Current byte position in input
     size_t input_length;                 // Total input buffer length in bytes
     glr_reader_t *reader;                // Token reader for UTF-16 input
     glr_lexer_hooks_t *lexer_hooks;      // Custom lexer hooks (optional)
     glr_reader_token_t lookahead;        // Current lookahead token
     glr_parse_error_t error;             // Most recent error code
     void *user_data;                     // User-provided context pointer
 };
 ```
 
 Key components:
 
 - **Grammar**: Defines the language being parsed
 - **Stacks**: Array of active parse stacks (the GSS)
 - **Forest**: Accumulates parse trees as parsing progresses
 - **Parse table**: ACTION and GOTO tables for LR parsing
 - **Input tracking**: Current position and lookahead token
 - **Hooks**: Customization points for lexing and disambiguation
 
 ### 3.2.2 Parser Lifecycle
 
 **Creating a parser:**
 
 ```c
 glr_grammar_t *grammar = glr_grammar_load("grammar.txt");
 glr_parser_t *parser = glr_parser_create(grammar);
 ```
 
 The parser maintains a reference to the grammar but does not take ownership. The grammar must remain valid for the parser's lifetime.
 
 **Parsing input:**
 
 ```c
 const char *input = "1 + 2 * 3";
 glr_parse_result_t result = glr_parse(parser, input, strlen(input));
 
 if (result.error == GLR_PARSE_SUCCESS) {
     printf("Parse succeeded! Forest has %zu nodes\n", result.forest->node_count);
 } else {
     printf("Parse failed at position %zu\n", result.position);
 }
 ```
 
 **Resetting for reuse:**
 
 ```c
 glr_parser_reset(parser);
 // Parser is now ready for another parse operation
 ```
 
 **Destroying the parser:**
 
 ```c
 glr_parser_destroy(parser);
 ```
 
 ## 3.3 The GLR Parsing Algorithm
 
 ### 3.3.1 High-Level Overview
 
 The GLR algorithm is an extension of LR parsing that handles ambiguity by maintaining multiple parse stacks simultaneously. The algorithm proceeds as follows:
 
 1. **Initialize**: Create an initial stack with the start state
 2. **Loop**: For each input token:
    - For each active stack:
      - Lookup the action in the parse table
      - If **shift**: Push the new state onto the stack
      - If **reduce**: Pop states, create a forest node, push the goto state
      - If **conflict**: Fork the stack and pursue both actions
      - If **accept**: Mark the parse as successful
      - If **error**: Remove this stack from the active set
    - Merge stacks that reach the same state
 3. **Finish**: If any stack accepted, return the forest; otherwise, report error
 
 ### 3.3.2 Detailed Algorithm
 
 Here's a simplified implementation of the GLR parsing loop:
 
 ```c
 glr_parse_result_t glr_parse(glr_parser_t *parser, const char *input, size_t length) {
     glr_parse_result_t result = {0};
     
     // Reset parser state
     glr_parser_reset(parser);
     parser->input = input;
     parser->input_length = length;
     parser->input_pos = 0;
     
     // Create initial stack with start state (state 0)
     glr_stack_t *initial_stack = glr_stack_create();
     glr_stack_push(initial_stack, (void *)(intptr_t)0);
     parser->stacks[0] = initial_stack;
     parser->stack_count = 1;
     
     // Main parsing loop
     while (parser->stack_count > 0) {
         // Get next token
         glr_reader_token_t token = read_next_token(parser);
         
         // Process each active stack
         size_t original_count = parser->stack_count;
         for (size_t i = 0; i < original_count; i++) {
             glr_stack_t *stack = parser->stacks[i];
             if (stack == NULL) continue;
             
             // Get current state
             int state = (int)(intptr_t)glr_stack_peek(stack);
             
             // Lookup action in parse table
             glr_action_entry_t *actions = lookup_actions(parser->parse_table, state, token.type);
             
             if (actions == NULL || actions[0].action == GLR_ACTION_ERROR) {
                 // No valid action - remove this stack
                 glr_stack_destroy(stack);
                 parser->stacks[i] = NULL;
                 continue;
             }
             
             // Handle conflicts by forking
             for (size_t j = 0; actions[j].action != GLR_ACTION_ERROR; j++) {
                 glr_stack_t *current_stack = (j == 0) ? stack : glr_stack_fork(stack, stack->height);
                 
                 if (actions[j].action == GLR_ACTION_SHIFT) {
                     // Shift: push new state, create terminal node
                     glr_stack_push(current_stack, (void *)(intptr_t)actions[j].target);
                     
                     glr_forest_node_t *terminal = glr_forest_get_node(
                         parser->forest, 
                         GLR_NODE_TERMINAL, 
                         token.type, 
                         parser->input_pos
                     );
                 }
                 else if (actions[j].action == GLR_ACTION_REDUCE) {
                     // Reduce: pop states, create non-terminal node
                     glr_production_t *prod = glr_grammar_get_production(
                         parser->grammar, 
                         actions[j].target
                     );
                     
                     // Pop production body length
                     for (size_t k = 0; k < prod->body_length; k++) {
                         glr_stack_pop(current_stack);
                     }
                     
                     // Create non-terminal node
                     glr_forest_node_t *nonterminal = glr_forest_get_node(
                         parser->forest, 
                         GLR_NODE_NONTERMINAL, 
                         prod->head->id, 
                         parser->input_pos
                     );
                     
                     // Push goto state
                     int goto_state = lookup_goto(
                         parser->parse_table, 
                         (int)(intptr_t)glr_stack_peek(current_stack), 
                         prod->head->id
                     );
                     glr_stack_push(current_stack, (void *)(intptr_t)goto_state);
                 }
                 else if (actions[j].action == GLR_ACTION_ACCEPT) {
                     // Accept: parsing succeeded
                     result.error = GLR_PARSE_SUCCESS;
                     result.forest = parser->forest;
                     result.position = parser->input_pos;
                     return result;
                 }
                 
                 // Add forked stack to active set
                 if (j > 0) {
                     parser->stacks[parser->stack_count++] = current_stack;
                 }
             }
         }
         
         // Merge stacks that reach the same state
         merge_stacks(parser);
         
         // Advance input position
         parser->input_pos += token.length;
     }
     
     // No stacks left - parse failed
     result.error = GLR_PARSE_ERROR_SYNTAX;
     result.position = parser->input_pos;
     return result;
 }
 ```
 
 ### 3.3.3 Action Types
 
 The parse table contains four types of actions:
 
 ```c
 typedef enum {
     GLR_ACTION_SHIFT,   // Shift: push new state
     GLR_ACTION_REDUCE,  // Reduce: apply production
     GLR_ACTION_ACCEPT,  // Accept: parsing succeeded
     GLR_ACTION_ERROR    // Error: no valid action
 } glr_action_type_t;
 ```
 
 **Shift action:**
 - Push the target state onto the stack
 - Create a terminal node in the forest
 - Advance to the next token
 
 **Reduce action:**
 - Pop states according to the production body length
 - Create a non-terminal node in the forest
 - Push the goto state for the production head
 - Do NOT advance to the next token (reprocess with the same token)
 
 **Accept action:**
 - Parsing completed successfully
 - Return the forest
 
 **Error action:**
 - No valid action for this state and token
 - Remove the stack from the active set
 
 ## 3.4 Stack Management
 
 ### 3.4.1 Multiple Stacks
 
 The parser maintains an array of active stacks:
 
 ```c
 glr_stack_t **stacks;      // Array of stack pointers
 size_t stack_count;        // Number of active stacks
 size_t stack_capacity;     // Allocated capacity
 ```
 
 Initially, there's one stack. When conflicts occur, the parser forks stacks to explore multiple paths.
 
 **Adding a stack:**
 
 ```c
 void add_stack(glr_parser_t *parser, glr_stack_t *stack) {
     if (parser->stack_count >= parser->stack_capacity) {
         // Grow the array
         parser->stack_capacity *= 2;
         parser->stacks = realloc(parser->stacks, 
                                  parser->stack_capacity * sizeof(glr_stack_t *));
     }
     parser->stacks[parser->stack_count++] = stack;
 }
 ```
 
 **Removing a stack:**
 
 ```c
 void remove_stack(glr_parser_t *parser, size_t index) {
     glr_stack_destroy(parser->stacks[index]);
     parser->stacks[index] = NULL;
     
     // Compact the array (optional)
     for (size_t i = index; i < parser->stack_count - 1; i++) {
         parser->stacks[i] = parser->stacks[i + 1];
     }
     parser->stack_count--;
 }
 ```
 
 ### 3.4.2 Forking
 
 Forking creates a copy of a stack to explore an alternative parse path. The `glr_fork_t` structure (from `include/glr/fork.h`) tracks fork points:
 
 ```c
 typedef struct glr_fork {
     size_t height;         // Height at which fork occurred
     struct glr_fork *next; // Next fork at same height
     void *context;         // Fork-specific context data
 } glr_fork_t;
 ```
 
 **Creating a fork:**
 
 ```c
 glr_fork_t *fork = glr_fork_create(stack->height);
 glr_fork_set_context(fork, some_data);
 ```
 
 **Forking a stack:**
 
 ```c
 glr_stack_t *original = parser->stacks[i];
 glr_stack_t *forked = glr_stack_fork(original, original->height);
 
 // Now we have two independent stacks
 add_stack(parser, forked);
 ```
 
 ### 3.4.3 Merging
 
 When multiple stacks reach the same state at the same input position, they can be merged to avoid redundant computation:
 
 ```c
 void merge_stacks(glr_parser_t *parser) {
     for (size_t i = 0; i < parser->stack_count; i++) {
         if (parser->stacks[i] == NULL) continue;
         
         int state_i = (int)(intptr_t)glr_stack_peek(parser->stacks[i]);
         
         for (size_t j = i + 1; j < parser->stack_count; j++) {
             if (parser->stacks[j] == NULL) continue;
             
             int state_j = (int)(intptr_t)glr_stack_peek(parser->stacks[j]);
             
             if (state_i == state_j) {
                 // Same state - merge j into i
                 // (In practice, this involves merging the GSS nodes)
                 glr_stack_destroy(parser->stacks[j]);
                 parser->stacks[j] = NULL;
             }
         }
     }
     
     // Compact the array
     size_t write_pos = 0;
     for (size_t read_pos = 0; read_pos < parser->stack_count; read_pos++) {
         if (parser->stacks[read_pos] != NULL) {
             parser->stacks[write_pos++] = parser->stacks[read_pos];
         }
     }
     parser->stack_count = write_pos;
 }
 ```
 
 ## 3.5 Handling Conflicts
 
 ### 3.5.1 Shift-Reduce Conflicts
 
 A shift-reduce conflict occurs when the parse table has both a shift and a reduce action for the same state and lookahead token.
 
 **Example: Dangling else**
 
 ```
 if (a) if (b) x = 1; else x = 2;
 ```
 
 When the parser sees `else`, it can:
 - **Shift**: Associate `else` with the inner `if`
 - **Reduce**: Complete the inner `if` and associate `else` with the outer `if`
 
 **Handling in LibGLR:**
 
 ```c
 glr_action_entry_t actions[] = {
     {state, ELSE, GLR_ACTION_SHIFT, target_state},
     {state, ELSE, GLR_ACTION_REDUCE, production_id},
     {0, 0, GLR_ACTION_ERROR, 0}  // Sentinel
 };
 
 // Fork the stack
 glr_stack_t *stack1 = parser->stacks[i];
 glr_stack_t *stack2 = glr_stack_fork(stack1, stack1->height);
 
 // Path 1: Shift
 glr_stack_push(stack1, (void *)(intptr_t)target_state);
 
 // Path 2: Reduce
 perform_reduction(parser, stack2, production_id);
 
 // Add forked stack
 add_stack(parser, stack2);
 ```
 
 ### 3.5.2 Reduce-Reduce Conflicts
 
 A reduce-reduce conflict occurs when multiple reductions are possible for the same state and lookahead.
 
 **Example: Ambiguous grammar**
 
 ```
 A → x
 B → x
 ```
 
 When the parser sees `x`, it can reduce by either production.
 
 **Handling in LibGLR:**
 
 ```c
 glr_action_entry_t actions[] = {
     {state, X, GLR_ACTION_REDUCE, prod_A},
     {state, X, GLR_ACTION_REDUCE, prod_B},
     {0, 0, GLR_ACTION_ERROR, 0}
 };
 
 // Fork for each reduction
 glr_stack_t *stack1 = parser->stacks[i];
 glr_stack_t *stack2 = glr_stack_fork(stack1, stack1->height);
 
 // Path 1: Reduce by A
 perform_reduction(parser, stack1, prod_A);
 
 // Path 2: Reduce by B
 perform_reduction(parser, stack2, prod_B);
 
 add_stack(parser, stack2);
 ```
 
 ### 3.5.3 Conflict Resolution Strategies
 
 While GLR parsers can handle conflicts by forking, it's often desirable to resolve them using disambiguation strategies (covered in Chapter 7):
 
 - **Precedence**: Prefer shift over reduce for operators with higher precedence
 - **Associativity**: Prefer left or right association for operators
 - **Semantic predicates**: Use runtime information to choose the correct path
 - **Probability**: Choose the most likely parse based on training data
 
 ## 3.6 Error Handling
 
 ### 3.6.1 Error Types
 
 LibGLR defines several error types:
 
 ```c
 typedef enum {
     GLR_PARSE_SUCCESS = 0,        // Parsing completed successfully
     GLR_PARSE_ERROR_SYNTAX,       // Syntax error in input
     GLR_PARSE_ERROR_MEMORY,       // Memory allocation failure
     GLR_PARSE_ERROR_GRAMMAR,      // Invalid or malformed grammar
     GLR_PARSE_ERROR_UNRECOVERABLE // Unrecoverable parse error (no valid paths)
 } glr_parse_error_t;
 ```
 
 ### 3.6.2 Error Detection
 
 Errors are detected when:
 - All stacks encounter error actions (no valid parse paths)
 - Memory allocation fails
 - The grammar is invalid or incomplete
 
 **Example: Detecting syntax errors**
 
 ```c
 glr_parse_result_t result = glr_parse(parser, input, length);
 
 if (result.error == GLR_PARSE_ERROR_SYNTAX) {
     printf("Syntax error at position %zu\n", result.position);
     
     // Show context
     size_t start = (result.position > 20) ? result.position - 20 : 0;
     size_t end = (result.position + 20 < length) ? result.position + 20 : length;
     
     printf("Context: %.*s\n", (int)(end - start), input + start);
     printf("         %*s^\n", (int)(result.position - start), "");
 }
 ```
 
 ### 3.6.3 Error Recovery
 
 LibGLR does not currently implement automatic error recovery. When all stacks fail, parsing stops. However, you can implement custom error recovery by:
 
 1. Catching the error
 2. Skipping tokens until a synchronization point (e.g., semicolon, closing brace)
 3. Restarting the parser from that point
 
 **Example: Simple error recovery**
 
 ```c
 glr_parse_result_t result = glr_parse(parser, input, length);
 
 if (result.error == GLR_PARSE_ERROR_SYNTAX) {
     // Skip to next semicolon
     size_t pos = result.position;
     while (pos < length && input[pos] != ';') {
         pos++;
     }
     
     if (pos < length) {
         // Try parsing from here
         glr_parser_reset(parser);
         result = glr_parse(parser, input + pos + 1, length - pos - 1);
     }
 }
 ```
 
 ## 3.7 Complete Example: Expression Parser
 
 Here's a complete example that demonstrates parser usage with stack management:
 
 ```c
 #include <stdio.h>
 #include <stdlib.h>
 #include <string.h>
 #include <glr/glr.h>
 
 // Build a simple expression grammar
 glr_grammar_t *build_expr_grammar(void) {
     glr_grammar_t *grammar = glr_grammar_create();
     
     // Terminals
     int NUMBER = glr_grammar_add_symbol(grammar, GLR_SYMBOL_TERMINAL, "NUMBER");
     int PLUS = glr_grammar_add_symbol(grammar, GLR_SYMBOL_TERMINAL, "+");
     int TIMES = glr_grammar_add_symbol(grammar, GLR_SYMBOL_TERMINAL, "*");
     int LPAREN = glr_grammar_add_symbol(grammar, GLR_SYMBOL_TERMINAL, "(");
     int RPAREN = glr_grammar_add_symbol(grammar, GLR_SYMBOL_TERMINAL, ")");
     
     // Non-terminals
     int expr = glr_grammar_add_symbol(grammar, GLR_SYMBOL_NONTERMINAL, "expr");
     int term = glr_grammar_add_symbol(grammar, GLR_SYMBOL_NONTERMINAL, "term");
     int factor = glr_grammar_add_symbol(grammar, GLR_SYMBOL_NONTERMINAL, "factor");
     
     // Productions
     glr_symbol_t *expr_sym = glr_grammar_get_symbol(grammar, expr);
     glr_symbol_t *term_sym = glr_grammar_get_symbol(grammar, term);
     glr_symbol_t *factor_sym = glr_grammar_get_symbol(grammar, factor);
     glr_symbol_t *plus_sym = glr_grammar_get_symbol(grammar, PLUS);
     glr_symbol_t *times_sym = glr_grammar_get_symbol(grammar, TIMES);
     glr_symbol_t *lparen_sym = glr_grammar_get_symbol(grammar, LPAREN);
     glr_symbol_t *rparen_sym = glr_grammar_get_symbol(grammar, RPAREN);
     glr_symbol_t *number_sym = glr_grammar_get_symbol(grammar, NUMBER);
     
     // expr → expr + term
     glr_symbol_t *body1[] = {expr_sym, plus_sym, term_sym};
     glr_grammar_add_production(grammar, expr, body1, 3);
     
     // expr → term
     glr_symbol_t *body2[] = {term_sym};
     glr_grammar_add_production(grammar, expr, body2, 1);
     
     // term → term * factor
     glr_symbol_t *body3[] = {term_sym, times_sym, factor_sym};
     glr_grammar_add_production(grammar, term, body3, 3);
     
     // term → factor
     glr_symbol_t *body4[] = {factor_sym};
     glr_grammar_add_production(grammar, term, body4, 1);
     
     // factor → ( expr )
     glr_symbol_t *body5[] = {lparen_sym, expr_sym, rparen_sym};
     glr_grammar_add_production(grammar, factor, body5, 3);
     
     // factor → NUMBER
     glr_symbol_t *body6[] = {number_sym};
     glr_grammar_add_production(grammar, factor, body6, 1);
     
     // Set start symbol
     glr_grammar_set_start_symbol(grammar, expr);
     
     return grammar;
 }
 
 int main(void) {
     // Build grammar
     glr_grammar_t *grammar = build_expr_grammar();
     
     // Generate parse table (simplified - normally done by external tool)
     glr_parse_table_t *table = generate_lr_table(grammar);
     glr_grammar_set_parse_table(grammar, table, true);
     
     // Create parser
     glr_parser_t *parser = glr_parser_create(grammar);
     
     // Parse input
     const char *input = "1 + 2 * 3";
     glr_parse_result_t result = glr_parse(parser, input, strlen(input));
     
     if (result.error == GLR_PARSE_SUCCESS) {
         printf("Parse succeeded!\n");
         printf("Forest has %zu nodes\n", result.forest->node_count);
         printf("Number of parse trees: %zu\n", count_parse_trees(result.forest));
     } else {
         printf("Parse failed at position %zu\n", result.position);
     }
     
     // Cleanup
     glr_parser_destroy(parser);
     glr_grammar_destroy(grammar);
     
     return 0;
 }
 ```
 
 ## 3.8 Performance Considerations
 
 ### 3.8.1 Stack Count
 
 The number of active stacks grows with the degree of ambiguity in the grammar. For highly ambiguous grammars, this can lead to exponential blowup. Strategies to mitigate:
 
 - **Disambiguation**: Use precedence and associativity to reduce conflicts
 - **Grammar rewriting**: Transform the grammar to reduce ambiguity (Chapter 8)
 - **Stack merging**: Aggressively merge stacks that reach the same state
 
 ### 3.8.2 Memory Usage
 
 Each stack consumes memory proportional to its height. With many stacks, memory usage can be significant. The GSS structure helps by sharing common prefixes, but forking still creates new nodes.
 
 ### 3.8.3 Time Complexity
 
 GLR parsing has worst-case time complexity of $O(n^3)$ for highly ambiguous grammars, where $n$ is the input length. For practical grammars with limited ambiguity, it's closer to $O(n)$.
 
 ## 3.9 Summary
 
 This chapter covered the parser and stack management in LibGLR:
 
 - The parser orchestrates the GLR algorithm using grammar, stacks, and forest
 - Multiple stacks are maintained to explore different parse paths
 - Conflicts are handled by forking stacks
 - Stacks can be merged when they reach the same state
 - Error handling detects syntax errors and reports the failure position
 
 Key takeaways:
 
 - Use `glr_parser_create()` to create a parser from a grammar
 - Call `glr_parse()` to parse input and get a result
 - The parser automatically handles forking and merging
 - Check the result error code to detect parse failures
 
 The next chapter explores forest construction and the SPPF in detail.
