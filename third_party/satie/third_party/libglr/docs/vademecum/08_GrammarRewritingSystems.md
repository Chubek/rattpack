 # Chapter 8: Grammar Rewriting Systems
 
 ## 8.1 Overview
 
 Grammar rewriting transforms grammars to improve parsing efficiency or eliminate ambiguity. LibGLR provides the GLR Rewrite Language (GRL) in `include/glr/rewrite.h` and standard rewrite rules in `rewritelib/*.grl`.
 
 ## 8.2 Rewrite System Architecture
 
 ```c
 typedef enum {
     GLR_REWRITE_RULE_ADD_SYMBOL,
     GLR_REWRITE_RULE_DROP_SYMBOL,
     GLR_REWRITE_RULE_RENAME_SYMBOL,
     GLR_REWRITE_RULE_SET_START,
     GLR_REWRITE_RULE_ADD_PRODUCTION,
     GLR_REWRITE_RULE_DROP_PRODUCTION,
     GLR_REWRITE_RULE_REMOVE_EPSILON_PRODUCTIONS,
     GLR_REWRITE_RULE_REMOVE_UNIT_PRODUCTIONS,
     GLR_REWRITE_RULE_REMOVE_USELESS_SYMBOLS,
     GLR_REWRITE_RULE_REMOVE_LEFT_RECURSION,
     GLR_REWRITE_RULE_LEFT_FACTOR,
     GLR_REWRITE_RULE_MAKE_LR_COMPATIBLE,
     GLR_REWRITE_RULE_ELIMINATE_AMBIGUITY
 } glr_rewrite_rule_kind_t;
 
 typedef struct {
     char *name;
     glr_rewrite_rule_t *rules;
     size_t rule_count;
     size_t rule_capacity;
 } glr_rewrite_program_t;
 ```
 
 ## 8.3 Standard Rewrite Rules
 
 ### 8.3.1 Eliminate Epsilon Productions
 
 From `rewritelib/eliminate-epsilon-production.grl`:
 
 Removes productions of the form `A → ε`:
 
 ```lisp
 (rewrite eliminate-epsilon-productions
   (for-each production
     (if (is-epsilon production)
       (drop-production production)
       (add-alternatives-without-nullable production))))
 ```
 
 **Example:**
 
 Before:
 ```
 S → A B
 A → a | ε
 B → b
 ```
 
 After:
 ```
 S → A B | B
 A → a
 B → b
 ```
 
 ### 8.3.2 Remove Left Recursion
 
 From `rewritelib/remove-left-recursion.grl`:
 
 Transforms left-recursive productions to right-recursive:
 
 ```lisp
 (rewrite remove-left-recursion
   (for-each nonterminal
     (if (is-left-recursive nonterminal)
       (transform-to-right-recursive nonterminal))))
 ```
 
 **Example:**
 
 Before:
 ```
 E → E + T | T
 ```
 
 After:
 ```
 E → T E'
 E' → + T E' | ε
 ```
 
 ### 8.3.3 Left Factoring
 
 From `rewritelib/left-factor.grl`:
 
 Factors common prefixes:
 
 ```lisp
 (rewrite left-factor
   (for-each nonterminal
     (let ((common-prefix (find-common-prefix nonterminal)))
       (if common-prefix
         (factor-out common-prefix)))))
 ```
 
 **Example:**
 
 Before:
 ```
 S → if E then S else S
   | if E then S
 ```
 
 After:
 ```
 S → if E then S S'
 S' → else S | ε
 ```
 
 ### 8.3.4 Make LR-Compatible
 
 From `rewritelib/make-lr-compat.grl`:
 
 Applies multiple transformations to make grammar LR-parseable:
 
 ```lisp
 (rewrite make-lr-compatible
   (remove-epsilon-productions)
   (remove-unit-productions)
   (remove-left-recursion)
   (left-factor))
 ```
 
 ## 8.4 Using Rewrite Programs
 
 ### 8.4.1 Loading from File
 
 ```c
 glr_rewrite_program_t *program = glr_rewrite_program_load("remove-left-recursion.grl");
 if (!program) {
     fprintf(stderr, "Failed to load rewrite program\n");
     return 1;
 }
 
 glr_rewrite_report_t report;
 glr_rewrite_status_t status = glr_rewrite_apply(program, grammar, &report);
 
 if (status == GLR_REWRITE_STATUS_OK) {
     printf("Applied %zu rules\n", report.rules_applied);
 } else {
     fprintf(stderr, "Rewrite failed: %s\n", report.message);
 }
 
 glr_rewrite_program_destroy(program);
 ```
 
 ### 8.4.2 Building Programmatically
 
 ```c
 glr_rewrite_program_t *program = glr_rewrite_program_create("my_rewrite");
 
 // Add rule: remove epsilon productions
 glr_rewrite_rule_t rule1 = {
     .kind = GLR_REWRITE_RULE_REMOVE_EPSILON_PRODUCTIONS
 };
 glr_rewrite_program_add_rule(program, &rule1);
 
 // Add rule: remove left recursion
 glr_rewrite_rule_t rule2 = {
     .kind = GLR_REWRITE_RULE_REMOVE_LEFT_RECURSION
 };
 glr_rewrite_program_add_rule(program, &rule2);
 
 // Apply
 glr_rewrite_apply(program, grammar, NULL);
 
 glr_rewrite_program_destroy(program);
 ```
 
 ## 8.5 Custom Rewrite Rules
 
 ### 8.5.1 Adding a Symbol
 
 ```c
 glr_rewrite_rule_t rule = {
     .kind = GLR_REWRITE_RULE_ADD_SYMBOL,
     .data.symbol = {
         .type = GLR_SYMBOL_NONTERMINAL,
         .name = "new_symbol"
     }
 };
 glr_rewrite_program_add_rule(program, &rule);
 ```
 
 ### 8.5.2 Adding a Production
 
 ```c
 glr_rewrite_symbol_spec_t body[] = {
     {GLR_SYMBOL_NONTERMINAL, "expr"},
     {GLR_SYMBOL_TERMINAL, "+"},
     {GLR_SYMBOL_NONTERMINAL, "term"}
 };
 
 glr_rewrite_rule_t rule = {
     .kind = GLR_REWRITE_RULE_ADD_PRODUCTION,
     .data.production = {
         .head_name = "expr",
         .body = body,
         .body_length = 3
     }
 };
 glr_rewrite_program_add_rule(program, &rule);
 ```
 
 ### 8.5.3 Renaming a Symbol
 
 ```c
 glr_rewrite_rule_t rule = {
     .kind = GLR_REWRITE_RULE_RENAME_SYMBOL,
     .data.rename_symbol = {
         .old_name = "old_name",
         .new_name = "new_name"
     }
 };
 glr_rewrite_program_add_rule(program, &rule);
 ```
 
 ## 8.6 Rewrite Pipeline Example
 
 ```c
 #include <glr/glr.h>
 
 int main(void) {
     // Load original grammar
     glr_grammar_t *grammar = glr_grammar_load("original.grammar");
     
     // Create rewrite pipeline
     glr_rewrite_program_t *pipeline = glr_rewrite_program_create("pipeline");
     
     // Step 1: Remove epsilon productions
     glr_rewrite_rule_t rule1 = {
         .kind = GLR_REWRITE_RULE_REMOVE_EPSILON_PRODUCTIONS
     };
     glr_rewrite_program_add_rule(pipeline, &rule1);
     
     // Step 2: Remove unit productions
     glr_rewrite_rule_t rule2 = {
         .kind = GLR_REWRITE_RULE_REMOVE_UNIT_PRODUCTIONS
     };
     glr_rewrite_program_add_rule(pipeline, &rule2);
     
     // Step 3: Remove left recursion
     glr_rewrite_rule_t rule3 = {
         .kind = GLR_REWRITE_RULE_REMOVE_LEFT_RECURSION
     };
     glr_rewrite_program_add_rule(pipeline, &rule3);
     
     // Step 4: Left factor
     glr_rewrite_rule_t rule4 = {
         .kind = GLR_REWRITE_RULE_LEFT_FACTOR
     };
     glr_rewrite_program_add_rule(pipeline, &rule4);
     
     // Apply pipeline
     glr_rewrite_report_t report;
     glr_rewrite_status_t status = glr_rewrite_apply(pipeline, grammar, &report);
     
     if (status == GLR_REWRITE_STATUS_OK) {
         printf("Rewrite successful!\n");
         printf("Rules applied: %zu\n", report.rules_applied);
         
         // Save transformed grammar
         glr_grammar_save(grammar, "transformed.grammar");
     } else {
         fprintf(stderr, "Rewrite failed: %s\n", report.message);
     }
     
     // Cleanup
     glr_rewrite_program_destroy(pipeline);
     glr_grammar_destroy(grammar);
     
     return 0;
 }
 ```
 
 ## 8.7 Summary
 
 - Grammar rewriting transforms grammars for efficiency and correctness
 - Standard rules: epsilon elimination, left recursion removal, left factoring
 - GRL provides declarative rewrite language
 - Rewrite programs can be loaded from files or built programmatically
 - Pipelines apply multiple transformations in sequence
