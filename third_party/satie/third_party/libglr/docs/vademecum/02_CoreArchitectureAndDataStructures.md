 # Chapter 2: Core Architecture and Data Structures
 
 ## 2.1 Overview
 
 LibGLR's architecture is built around three fundamental data structures that work together to implement GLR parsing:
 
 1. **Grammar (`glr_grammar_t`)**: Represents the context-free grammar with symbols, productions, and parse tables
 2. **Graph-Structured Stack (`glr_stack_t`)**: Manages parser states as a DAG to handle multiple parse paths
 3. **Shared Packed Parse Forest (`glr_forest_t`)**: Compactly represents all possible parse trees
 
 This chapter explores each structure in detail, explaining their design, implementation, and usage patterns.
 
 ## 2.2 Grammar Representation
 
 ### 2.2.1 The Grammar Structure
 
 The `glr_grammar_t` structure is defined in `include/glr/grammar.h`:
 
 ```c
 typedef struct {
     glr_symbol_t **symbols;         // All symbols (terminals + non-terminals)
     size_t symbol_count;            // Number of symbols
     glr_production_t **productions; // All productions
     size_t production_count;        // Number of productions
     glr_symbol_t *start_symbol;     // Grammar start symbol
     char *name;                     // Grammar name
     glr_parse_table_t *parse_table; // Optional parse table for LR/GLR actions
     bool owns_parse_table;          // Whether the grammar destroys parse_table
 } glr_grammar_t;
 ```
 
 A grammar contains:
 - **Symbols**: Both terminals (tokens) and non-terminals (syntactic categories)
 - **Productions**: Rules that define how non-terminals expand
 - **Start symbol**: The root of the grammar
 - **Parse table**: Precomputed ACTION and GOTO tables for efficient parsing
 
 ### 2.2.2 Symbols
 
 Symbols are the atomic units of a grammar. Each symbol has a type, ID, and name:
 
 ```c
 typedef enum {
     GLR_SYMBOL_TERMINAL,    // Terminal symbol (token)
     GLR_SYMBOL_NONTERMINAL  // Non-terminal symbol
 } glr_symbol_type_t;
 
 typedef struct {
     glr_symbol_type_t type; // Type of symbol
     int id;                 // Unique identifier
     char *name;             // Symbol name (e.g., "+", "expression")
 } glr_symbol_t;
 ```
 
 **Example: Creating symbols**
 
 ```c
 glr_grammar_t *grammar = glr_grammar_create();
 
 // Add terminal symbols (tokens)
 int plus_id = glr_grammar_add_symbol(grammar, GLR_SYMBOL_TERMINAL, "+");
 int number_id = glr_grammar_add_symbol(grammar, GLR_SYMBOL_TERMINAL, "NUMBER");
 
 // Add non-terminal symbols
 int expr_id = glr_grammar_add_symbol(grammar, GLR_SYMBOL_NONTERMINAL, "expr");
 int term_id = glr_grammar_add_symbol(grammar, GLR_SYMBOL_NONTERMINAL, "term");
 
 // Retrieve a symbol by ID
 glr_symbol_t *expr_sym = glr_grammar_get_symbol(grammar, expr_id);
 printf("Symbol: %s (type: %s)\n", 
        expr_sym->name,
        glr_symbol_is_terminal(expr_sym) ? "terminal" : "non-terminal");
 ```
 
 ### 2.2.3 Productions
 
 Productions define the grammar rules. Each production has a head (left-hand side non-terminal) and a body (right-hand side sequence of symbols):
 
 ```c
 typedef struct {
     int id;              // Unique production identifier
     glr_symbol_t *head;  // Head non-terminal
     glr_symbol_t **body; // Body symbols (array)
     size_t body_length;  // Number of symbols in body
     char *annotation;    // Optional production annotation
 } glr_production_t;
 ```
 
 **Example: Adding productions**
 
 ```c
 // Grammar: expr → expr + term | term
 
 glr_grammar_t *grammar = glr_grammar_create();
 
 // Add symbols
 int expr_id = glr_grammar_add_symbol(grammar, GLR_SYMBOL_NONTERMINAL, "expr");
 int term_id = glr_grammar_add_symbol(grammar, GLR_SYMBOL_NONTERMINAL, "term");
 int plus_id = glr_grammar_add_symbol(grammar, GLR_SYMBOL_TERMINAL, "+");
 
 // Get symbol pointers
 glr_symbol_t *expr_sym = glr_grammar_get_symbol(grammar, expr_id);
 glr_symbol_t *term_sym = glr_grammar_get_symbol(grammar, term_id);
 glr_symbol_t *plus_sym = glr_grammar_get_symbol(grammar, plus_id);
 
 // Production 1: expr → expr + term
 glr_symbol_t *body1[] = {expr_sym, plus_sym, term_sym};
 int prod1_id = glr_grammar_add_production(grammar, expr_id, body1, 3);
 
 // Production 2: expr → term
 glr_symbol_t *body2[] = {term_sym};
 int prod2_id = glr_grammar_add_production(grammar, expr_id, body2, 1);
 
 // Set start symbol
 glr_grammar_set_start_symbol(grammar, expr_id);
 ```
 
 ### 2.2.4 Parse Tables
 
 Parse tables contain the ACTION and GOTO entries that drive the parser. They are defined in `include/glr/parsetbl.h`:
 
 ```c
 typedef struct {
     int state;           // Parser state
     int symbol;          // Terminal or non-terminal symbol
     glr_action_type_t action; // Action type (shift, reduce, accept, error)
     int target;          // Target state (for shift) or production (for reduce)
 } glr_action_entry_t;
 
 typedef struct {
     glr_action_entry_t **action_table; // ACTION table
     size_t action_count;               // Number of ACTION entries
     int **goto_table;                  // GOTO table
     size_t goto_count;                 // Number of GOTO entries
     size_t state_count;                // Number of parser states
 } glr_parse_table_t;
 ```
 
 Parse tables are typically generated by external tools (like Bison or a custom LR table generator) and attached to the grammar:
 
 ```c
 glr_parse_table_t *table = generate_parse_table(grammar);
 glr_grammar_set_parse_table(grammar, table, true); // true = grammar owns table
 ```
 
 ## 2.3 Graph-Structured Stack (GSS)
 
 ### 2.3.1 Why a DAG-Based Stack?
 
 Traditional LR parsers use a linear stack to track parser states. When the parser shifts, it pushes a state; when it reduces, it pops states. This works for deterministic parsing but fails for ambiguous grammars.
 
 GLR parsers need to explore multiple parse paths simultaneously. Instead of choosing one action at a conflict, they pursue all possibilities. This requires a **Graph-Structured Stack (GSS)**, which is a DAG where:
 
 - **Nodes** represent parser states at specific input positions
 - **Edges** represent transitions between states
 - **Paths** from root to a node represent different stack configurations
 
 When the parser forks (due to a shift-reduce or reduce-reduce conflict), it creates multiple paths in the GSS. Paths can merge when they reach the same state, sharing computation and avoiding exponential blowup.
 
 ### 2.3.2 Stack Structure
 
 The stack is defined in `include/glr/stack.h`:
 
 ```c
 typedef struct glr_stack_node glr_stack_node_t;
 
 typedef struct {
     glr_stack_node_t *root; // Stack root node
     size_t height;          // Current stack height
     void **states;          // Array of parser states
     size_t capacity;        // Stack capacity
 } glr_stack_t;
 ```
 
 Each `glr_stack_node_t` represents a node in the DAG. The structure is opaque, but conceptually it contains:
 - A parser state (integer)
 - A list of parent nodes (for merging paths)
 - A list of child nodes (for forking paths)
 
 ### 2.3.3 Stack Operations
 
 **Creating a stack:**
 
 ```c
 glr_stack_t *stack = glr_stack_create();
 ```
 
 **Pushing a state:**
 
 ```c
 int state = 5;
 glr_stack_push(stack, (void *)(intptr_t)state);
 ```
 
 **Peeking at the top:**
 
 ```c
 void *top = glr_stack_peek(stack);
 int state = (int)(intptr_t)top;
 ```
 
 **Popping a state:**
 
 ```c
 void *popped = glr_stack_pop(stack);
 ```
 
 **Forking the stack:**
 
 When the parser encounters a conflict, it forks the stack:
 
 ```c
 glr_stack_t *fork = glr_stack_fork(stack, stack->height);
 
 // Now we have two independent stacks
 glr_stack_push(stack, (void *)(intptr_t)state1); // Original path
 glr_stack_push(fork, (void *)(intptr_t)state2);  // Forked path
 ```
 
 **Getting stack height:**
 
 ```c
 size_t height = glr_stack_height(stack);
 ```
 
 **Checking if empty:**
 
 ```c
 if (glr_stack_empty(stack)) {
     printf("Stack is empty\n");
 }
 ```
 
 ### 2.3.4 Example: Handling a Shift-Reduce Conflict
 
 Consider parsing `1 + 2 * 3` with an ambiguous grammar. At some point, the parser faces a shift-reduce conflict:
 
 - **Shift**: Read the `*` operator
 - **Reduce**: Reduce `1 + 2` to an expression
 
 The parser forks:
 
 ```c
 glr_stack_t *stack1 = stack;  // Original stack
 glr_stack_t *stack2 = glr_stack_fork(stack, stack->height);
 
 // Path 1: Shift
 glr_stack_push(stack1, (void *)(intptr_t)shift_state);
 
 // Path 2: Reduce
 // Pop states according to production length
 for (size_t i = 0; i < production_length; i++) {
     glr_stack_pop(stack2);
 }
 glr_stack_push(stack2, (void *)(intptr_t)reduce_state);
 ```
 
 Both stacks continue parsing independently. If they later reach the same state, they can merge, sharing the remaining computation.
 
 ## 2.4 Shared Packed Parse Forest (SPPF)
 
 ### 2.4.1 Why SPPF?
 
 An ambiguous grammar can produce multiple parse trees for the same input. Storing all trees explicitly would require exponential space. The **Shared Packed Parse Forest (SPPF)** solves this by:
 
 - **Sharing** common subtrees across different parse trees
 - **Packing** alternative derivations at ambiguity points
 
 The SPPF is a DAG where nodes represent grammar symbols at specific input positions, and edges represent derivations.
 
 ### 2.4.2 Forest Structure
 
 The forest is defined in `include/glr/forest.h`:
 
 ```c
 typedef enum {
     GLR_NODE_TERMINAL,    // Terminal node
     GLR_NODE_NONTERMINAL, // Non-terminal (split) node
     GLR_NODE_CONSTRUCTOR  // Constructor node
 } glr_forest_node_type_t;
 
 typedef struct glr_forest_node {
     glr_forest_node_type_t type; // Node type
     int symbol_id;               // Symbol ID (terminal or non-terminal)
     size_t position;             // Input position
     struct glr_forest_node **children; // Child nodes (for non-terminals)
     size_t child_count;                // Number of children
     size_t capacity;                   // Child capacity
     void *data;                        // Node-specific data
     struct glr_forest_node *next;      // Next sibling in same position
 } glr_forest_node_t;
 
 typedef struct {
     glr_forest_node_t **nodes; // All nodes indexed by position
     size_t node_count;         // Number of positions
     glr_forest_edge_t **edges; // All edges indexed by position
     size_t edge_count;         // Number of positions with edges
 } glr_forest_t;
 ```
 
 ### 2.4.3 Node Types
 
 **Terminal nodes** represent tokens:
 
 ```c
 glr_forest_node_t *node = glr_forest_get_node(
     forest, 
     GLR_NODE_TERMINAL, 
     number_symbol_id, 
     position
 );
 ```
 
 **Non-terminal nodes** represent syntactic categories:
 
 ```c
 glr_forest_node_t *expr_node = glr_forest_get_node(
     forest, 
     GLR_NODE_NONTERMINAL, 
     expr_symbol_id, 
     position
 );
 ```
 
 **Constructor nodes** combine children according to a production:
 
 ```c
 glr_forest_node_t *constructor = glr_forest_get_node(
     forest, 
     GLR_NODE_CONSTRUCTOR, 
     production_id, 
     position
 );
 
 // Add children
 glr_forest_add_child(constructor, left_child);
 glr_forest_add_child(constructor, operator_child);
 glr_forest_add_child(constructor, right_child);
 ```
 
 ### 2.4.4 Building the Forest During Parsing
 
 As the parser processes input, it builds the SPPF incrementally:
 
 **On shift:**
 
 ```c
 // Create a terminal node for the shifted token
 glr_forest_node_t *terminal = glr_forest_get_node(
     forest, 
     GLR_NODE_TERMINAL, 
     token.type, 
     token.position
 );
 ```
 
 **On reduce:**
 
 ```c
 // Get the production
 glr_production_t *prod = glr_grammar_get_production(grammar, production_id);
 
 // Create a non-terminal node for the head
 glr_forest_node_t *head_node = glr_forest_get_node(
     forest, 
     GLR_NODE_NONTERMINAL, 
     prod->head->id, 
     end_position
 );
 
 // Create a constructor node
 glr_forest_node_t *constructor = glr_forest_get_node(
     forest, 
     GLR_NODE_CONSTRUCTOR, 
     production_id, 
     start_position
 );
 
 // Add children from the production body
 for (size_t i = 0; i < prod->body_length; i++) {
     glr_forest_node_t *child = /* retrieve from stack */;
     glr_forest_add_child(constructor, child);
 }
 
 // Link constructor to head
 glr_forest_add_child(head_node, constructor);
 ```
 
 ### 2.4.5 Handling Ambiguity with Packed Nodes
 
 When multiple derivations produce the same non-terminal at the same position, the SPPF creates a **packed node** with multiple children:
 
 ```c
 // First derivation: expr → expr + term
 glr_forest_node_t *constructor1 = /* ... */;
 glr_forest_add_child(expr_node, constructor1);
 
 // Second derivation: expr → term
 glr_forest_node_t *constructor2 = /* ... */;
 glr_forest_add_child(expr_node, constructor2);
 
 // Now expr_node has two children, representing two parse trees
 ```
 
 ### 2.4.6 Example: SPPF for `1 + 2 * 3`
 
 Consider the ambiguous grammar:
 
 ```
 E → E + E
 E → E * E
 E → number
 ```
 
 Parsing `1 + 2 * 3` produces an SPPF with two derivations:
 
 **Derivation 1: (1 + 2) * 3**
 
 ```
 E[0,5]
   ├─ E[0,3] + E[3,5]
   │   ├─ E[0,1] (1)
   │   ├─ +
   │   └─ E[1,3] (2)
   ├─ *
   └─ E[3,5] (3)
 ```
 
 **Derivation 2: 1 + (2 * 3)**
 
 ```
 E[0,5]
   ├─ E[0,1] (1)
   ├─ +
   └─ E[1,5]
       ├─ E[1,3] (2)
       ├─ *
       └─ E[3,5] (3)
 ```
 
 The SPPF shares the common subtrees (the number nodes) and packs the two derivations at the root `E[0,5]` node.
 
 ## 2.5 Relationships Between Structures
 
 The three core structures work together during parsing:
 
 1. **Grammar** defines the rules and provides the parse table
 2. **Stack** tracks parser states and handles forking
 3. **Forest** records the parse trees being constructed
 
 **Parsing loop:**
 
 ```c
 glr_grammar_t *grammar = /* ... */;
 glr_stack_t *stack = glr_stack_create();
 glr_forest_t *forest = glr_forest_create();
 
 // Initialize stack with start state
 glr_stack_push(stack, (void *)(intptr_t)0);
 
 while (!done) {
     // Get current state
     int state = (int)(intptr_t)glr_stack_peek(stack);
     
     // Get next token
     glr_token_t token = read_token();
     
     // Lookup action in parse table
     glr_action_entry_t *action = lookup_action(grammar->parse_table, state, token.type);
     
     if (action->action == GLR_ACTION_SHIFT) {
         // Shift: push new state, create terminal node
         glr_stack_push(stack, (void *)(intptr_t)action->target);
         glr_forest_node_t *node = glr_forest_get_node(forest, GLR_NODE_TERMINAL, token.type, token.position);
     } 
     else if (action->action == GLR_ACTION_REDUCE) {
         // Reduce: pop states, create non-terminal node
         glr_production_t *prod = glr_grammar_get_production(grammar, action->target);
         
         // Pop production body length
         for (size_t i = 0; i < prod->body_length; i++) {
             glr_stack_pop(stack);
         }
         
         // Create non-terminal node in forest
         glr_forest_node_t *node = glr_forest_get_node(forest, GLR_NODE_NONTERMINAL, prod->head->id, token.position);
         
         // Push goto state
         int goto_state = lookup_goto(grammar->parse_table, (int)(intptr_t)glr_stack_peek(stack), prod->head->id);
         glr_stack_push(stack, (void *)(intptr_t)goto_state);
     }
     else if (action->action == GLR_ACTION_ACCEPT) {
         done = true;
     }
 }
 ```
 
 ## 2.6 Memory Management
 
 LibGLR follows a consistent memory management pattern:
 
 **Creation functions** allocate memory:
 
 ```c
 glr_grammar_t *grammar = glr_grammar_create();
 glr_stack_t *stack = glr_stack_create();
 glr_forest_t *forest = glr_forest_create();
 ```
 
 **Destruction functions** free all associated memory:
 
 ```c
 glr_grammar_destroy(grammar);
 glr_stack_destroy(stack);
 glr_forest_destroy(forest);
 ```
 
 **Ownership rules:**
 
 - When you add a symbol or production to a grammar, the grammar takes ownership
 - When you attach a parse table with `take_ownership=true`, the grammar will destroy it
 - When you fork a stack, the fork is independent and must be destroyed separately
 - Forest nodes are owned by the forest and destroyed with it
 
 **Example: Proper cleanup**
 
 ```c
 glr_grammar_t *grammar = glr_grammar_create();
 glr_grammar_add_symbol(grammar, GLR_SYMBOL_TERMINAL, "+");
 // ... add more symbols and productions ...
 
 glr_parse_table_t *table = generate_parse_table(grammar);
 glr_grammar_set_parse_table(grammar, table, true); // Grammar owns table
 
 glr_stack_t *stack = glr_stack_create();
 glr_forest_t *forest = glr_forest_create();
 
 // ... parsing ...
 
 // Cleanup (order doesn't matter)
 glr_forest_destroy(forest);
 glr_stack_destroy(stack);
 glr_grammar_destroy(grammar); // Also destroys parse table
 ```
 
 ## 2.7 Performance Considerations
 
 ### 2.7.1 Grammar Size
 
 - **Symbol count**: Linear impact on parse table size
 - **Production count**: Linear impact on reduce actions
 - **Parse table size**: $O(states \times symbols)$
 
 Large grammars benefit from parse table compression techniques (not covered here).
 
 ### 2.7.2 Stack Depth
 
 - Stack depth is bounded by input length and grammar recursion depth
 - Forking can create many stacks, but they share structure in the GSS
 - Merging reduces redundant computation
 
 ### 2.7.3 Forest Size
 
 - SPPF size is $O(n^3)$ in the worst case for highly ambiguous grammars
 - Sharing and packing keep it polynomial even with exponentially many parse trees
 - Disambiguation (Chapter 7) can reduce forest size by pruning alternatives
 
 ## 2.8 Summary
 
 This chapter covered the three core data structures of LibGLR:
 
 - **Grammar**: Symbols, productions, and parse tables
 - **Stack**: DAG-based stack for handling multiple parse paths
 - **Forest**: SPPF for compactly representing all parse trees
 
 Key takeaways:
 
 - Grammars are built incrementally by adding symbols and productions
 - The GSS allows forking and merging to handle ambiguity efficiently
 - The SPPF shares common subtrees and packs alternatives
 - Memory management follows a create/destroy pattern with clear ownership rules
 
 The next chapter explores how the parser uses these structures to implement the GLR algorithm.
