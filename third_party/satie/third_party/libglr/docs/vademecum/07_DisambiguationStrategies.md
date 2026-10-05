 # Chapter 7: Disambiguation Strategies
 
 ## 7.1 Overview
 
 GLR parsers produce all possible parse trees for ambiguous input. Disambiguation selects the "correct" tree based on various strategies. LibGLR provides a hook-based disambiguation system (`include/glr/disambiguate.h`) with built-in strategies in `disambstd/`.
 
 ## 7.2 Disambiguation Context
 
 ```c
 typedef struct {
     glr_parser_t *parser;                  // Parser currently resolving
     glr_grammar_t *grammar;                // Grammar
     glr_forest_t *forest;                  // Forest being disambiguated
     glr_forest_node_t *parent;             // Ambiguous parent node
     glr_disambig_candidate_t *candidates;  // Candidate array
     size_t candidate_count;                // Candidate count
     int lookahead_symbol_id;               // Current lookahead symbol
     size_t start_position;                 // Ambiguity span start
     size_t end_position;                   // Ambiguity span end
     void *user_data;                       // Caller-owned context payload
 } glr_disambig_context_t;
 
 typedef struct {
     glr_forest_node_t *node;               // Forest node
     glr_reduction_t *reduction;            // Reduction that created candidate
     glr_production_t *production;          // Grammar production
     int precedence;                        // Static or dynamic precedence
     glr_disambig_associativity_t associativity; // Associativity class
     double score;                          // Generic additive score
     double probability;                    // Generic multiplicative probability
     bool rejected;                         // Hook-maintained elimination flag
 } glr_disambig_candidate_t;
 ```
 
 ## 7.3 Disambiguation Hooks
 
 Hooks are functions that examine candidates and select winners:
 
 ```c
 typedef glr_disambig_result_t (*glr_disambig_fn)(
     glr_disambig_context_t *context, 
     size_t *winner_index, 
     void *user_data
 );
 
 typedef struct glr_disambig_hook {
     char *name;                       // Hook name
     unsigned int priority;            // Larger values run first
     glr_disambig_fn fn;               // Hook callback
     glr_disambig_destroy_fn destroy;  // Hook state destructor
     void *user_data;                  // Hook-owned state
     struct glr_disambig_hook *next;   // Linked-list successor
 } glr_disambig_hook_t;
 ```
 
 ### 7.3.1 Creating and Registering Hooks
 
 ```c
 glr_disambig_hook_t *hook = glr_disambig_hook_create(
     "my_hook",
     100,  // priority
     my_disambig_fn,
     my_data,
     my_destroy_fn
 );
 
 glr_parser_add_disambig_hook(parser, hook);
 ```
 
 ## 7.4 Built-in Strategies
 
 ### 7.4.1 Precedence-Based Disambiguation
 
 From `disambstd/precedence.c`:
 
 ```c
 glr_disambig_result_t precedence_disambig(
     glr_disambig_context_t *context,
     size_t *winner_index,
     void *user_data
 ) {
     int max_precedence = INT_MIN;
     size_t winner = 0;
     bool found = false;
     
     for (size_t i = 0; i < context->candidate_count; i++) {
         if (context->candidates[i].rejected) continue;
         
         if (context->candidates[i].precedence > max_precedence) {
             max_precedence = context->candidates[i].precedence;
             winner = i;
             found = true;
         }
     }
     
     if (found) {
         *winner_index = winner;
         return GLR_DISAMBIG_RESOLVED;
     }
     
     return GLR_DISAMBIG_NO_MATCH;
 }
 ```
 
 **Usage:**
 
 ```c
 glr_disambig_hook_t *prec_hook = glr_disambig_precedence_create();
 glr_parser_add_disambig_hook(parser, prec_hook);
 ```
 
 ### 7.4.2 Associativity-Based Disambiguation
 
 From `disambstd/associativity.c`:
 
 ```c
 glr_disambig_result_t associativity_disambig(
     glr_disambig_context_t *context,
     size_t *winner_index,
     void *user_data
 ) {
     // For left-associative operators, prefer left-recursive parse
     // For right-associative operators, prefer right-recursive parse
     
     for (size_t i = 0; i < context->candidate_count; i++) {
         if (context->candidates[i].rejected) continue;
         
         glr_disambig_associativity_t assoc = context->candidates[i].associativity;
         
         if (assoc == GLR_DISAMBIG_ASSOC_LEFT) {
             // Check if this is left-recursive
             if (is_left_recursive(context->candidates[i].production)) {
                 *winner_index = i;
                 return GLR_DISAMBIG_RESOLVED;
             }
         } else if (assoc == GLR_DISAMBIG_ASSOC_RIGHT) {
             // Check if this is right-recursive
             if (is_right_recursive(context->candidates[i].production)) {
                 *winner_index = i;
                 return GLR_DISAMBIG_RESOLVED;
             }
         }
     }
     
     return GLR_DISAMBIG_NO_MATCH;
 }
 ```
 
 ### 7.4.3 Semantic Predicate Disambiguation
 
 From `disambstd/semantic.c`:
 
 ```c
 typedef bool (*semantic_predicate_fn)(glr_disambig_candidate_t *candidate);
 
 glr_disambig_result_t semantic_disambig(
     glr_disambig_context_t *context,
     size_t *winner_index,
     void *user_data
 ) {
     semantic_predicate_fn predicate = (semantic_predicate_fn)user_data;
     
     for (size_t i = 0; i < context->candidate_count; i++) {
         if (context->candidates[i].rejected) continue;
         
         if (predicate(&context->candidates[i])) {
             *winner_index = i;
             return GLR_DISAMBIG_RESOLVED;
         }
     }
     
     return GLR_DISAMBIG_NO_MATCH;
 }
 ```
 
 **Example: Type-based disambiguation**
 
 ```c
 bool is_type_cast(glr_disambig_candidate_t *candidate) {
     // Check if this parse represents a type cast vs. multiplication
     // e.g., (int) * p  vs.  (int) *p
     
     // Look up symbol in symbol table
     if (candidate->production->body[0]->name) {
         return is_typename(candidate->production->body[0]->name);
     }
     return false;
 }
 
 glr_disambig_hook_t *semantic_hook = glr_disambig_hook_create(
     "type_cast",
     50,
     semantic_disambig,
     is_type_cast,
     NULL
 );
 ```
 
 ### 7.4.4 Probability-Based Disambiguation
 
 From `disambstd/probability.c`:
 
 ```c
 glr_disambig_result_t probability_disambig(
     glr_disambig_context_t *context,
     size_t *winner_index,
     void *user_data
 ) {
     double max_prob = 0.0;
     size_t winner = 0;
     bool found = false;
     
     for (size_t i = 0; i < context->candidate_count; i++) {
         if (context->candidates[i].rejected) continue;
         
         if (context->candidates[i].probability > max_prob) {
             max_prob = context->candidates[i].probability;
             winner = i;
             found = true;
         }
     }
     
     if (found) {
         *winner_index = winner;
         return GLR_DISAMBIG_RESOLVED;
     }
     
     return GLR_DISAMBIG_NO_MATCH;
 }
 ```
 
 Probabilities can be learned from training data or assigned manually.
 
 ### 7.4.5 Dynamic Programming Disambiguation
 
 From `disambstd/dynamic_programming.c`:
 
 Uses Viterbi algorithm to find the most likely parse tree based on production probabilities.
 
 ## 7.5 Combining Multiple Strategies
 
 Hooks run in priority order. Higher priority hooks run first:
 
 ```c
 // Priority 100: Precedence (highest)
 glr_parser_add_disambig_hook(parser, glr_disambig_precedence_create());
 
 // Priority 90: Associativity
 glr_parser_add_disambig_hook(parser, glr_disambig_associativity_create());
 
 // Priority 50: Semantic predicates
 glr_parser_add_disambig_hook(parser, semantic_hook);
 
 // Priority 10: Probability (fallback)
 glr_parser_add_disambig_hook(parser, glr_disambig_probability_create());
 ```
 
 ## 7.6 Custom Disambiguation Example
 
 ```c
 glr_disambig_result_t prefer_shorter_parse(
     glr_disambig_context_t *context,
     size_t *winner_index,
     void *user_data
 ) {
     size_t min_depth = SIZE_MAX;
     size_t winner = 0;
     bool found = false;
     
     for (size_t i = 0; i < context->candidate_count; i++) {
         if (context->candidates[i].rejected) continue;
         
         size_t depth = compute_tree_depth(context->candidates[i].node);
         
         if (depth < min_depth) {
             min_depth = depth;
             winner = i;
             found = true;
         }
     }
     
     if (found) {
         *winner_index = winner;
         return GLR_DISAMBIG_RESOLVED;
     }
     
     return GLR_DISAMBIG_NO_MATCH;
 }
 
 // Register
 glr_disambig_hook_t *hook = glr_disambig_hook_create(
     "prefer_shorter",
     20,
     prefer_shorter_parse,
     NULL,
     NULL
 );
 glr_parser_add_disambig_hook(parser, hook);
 ```
 
 ## 7.7 Summary
 
 - Disambiguation selects one parse tree from multiple alternatives
 - Hooks examine candidates and select winners
 - Built-in strategies: precedence, associativity, semantic predicates, probability
 - Hooks run in priority order
 - Custom hooks can implement domain-specific disambiguation logic
