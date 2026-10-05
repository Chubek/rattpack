 # Chapter 4: Forest Construction and SPPF
 
 ## 4.1 Overview
 
 The Shared Packed Parse Forest (SPPF) is the data structure that makes GLR parsing practical. Without it, representing all possible parse trees for an ambiguous input would require exponential space. The SPPF achieves polynomial space complexity by:
 
 - **Sharing** common subtrees across different parse trees
 - **Packing** alternative derivations at ambiguity points
 
 This chapter explores:
 
 - SPPF structure and node types
 - Building the forest during parsing
 - Handling ambiguity with packed nodes
 - Extracting individual parse trees
 - Forest merging for incremental parsing
 
 ## 4.2 SPPF Structure
 
 ### 4.2.1 Node Types
 
 The SPPF uses three types of nodes, defined in `include/glr/forest.h`:
 
 ```c
 typedef enum {
     GLR_NODE_TERMINAL,    // Terminal node (token)
     GLR_NODE_NONTERMINAL, // Non-terminal (split) node
     GLR_NODE_CONSTRUCTOR  // Constructor node (production application)
 } glr_forest_node_type_t;
 ```
 
 **Terminal nodes** represent tokens from the input:
 
 ```c
 typedef struct glr_forest_node {
     glr_forest_node_type_t type; // GLR_NODE_TERMINAL
     int symbol_id;               // Token type (e.g., NUMBER, PLUS)
     size_t position;             // Position in input
     struct glr_forest_node **children; // NULL for terminals
     size_t child_count;                // 0 for terminals
     size_t capacity;                   // 0 for terminals
     void *data;                        // Token value (e.g., "42")
     struct glr_forest_node *next;      // Next sibling at same position
 } glr_forest_node_t;
 ```
 
 **Non-terminal nodes** represent syntactic categories (e.g., `expr`, `stmt`):
 
 ```c
 // Same structure, but:
 // - type = GLR_NODE_NONTERMINAL
 // - children points to constructor nodes
 // - child_count > 0 if there are multiple derivations (ambiguity)
 ```
 
 **Constructor nodes** represent the application of a production:
 
 ```c
 // Same structure, but:
 // - type = GLR_NODE_CONSTRUCTOR
 // - symbol_id is the production ID
 // - children are the symbols in the production body
 ```
 
 ### 4.2.2 Forest Container
 
 The forest container manages all nodes:
 
 ```c
 typedef struct {
     glr_forest_node_t **nodes; // All nodes indexed by position
     size_t node_count;         // Number of positions
     glr_forest_edge_t **edges; // All edges indexed by position
     size_t edge_count;         // Number of positions with edges
 } glr_forest_t;
 ```
 
 Nodes are organized by input position, allowing efficient lookup and sharing.
 
 ### 4.2.3 Edges
 
 Edges connect nodes across different positions:
 
 ```c
 typedef struct glr_forest_edge {
     int nonterminal_id;           // Non-terminal on left-hand side
     size_t start_position;        // Starting position
     size_t end_position;          // Ending position
     struct glr_forest_edge *next; // Next edge at same position
 } glr_forest_edge_t;
 ```
 
 Edges are used to track which non-terminals span which input ranges, facilitating tree extraction and disambiguation.
 
 ## 4.3 Building the Forest During Parsing
 
 ### 4.3.1 On Shift: Creating Terminal Nodes
 
 When the parser shifts a token, it creates a terminal node:
 
 ```c
 void handle_shift(glr_parser_t *parser, glr_token_t token, int target_state) {
     // Push new state onto stack
     glr_stack_push(parser->stacks[i], (void *)(intptr_t)target_state);
     
     // Create terminal node in forest
     glr_forest_node_t *terminal = glr_forest_get_node(
         parser->forest,
         GLR_NODE_TERMINAL,
         token.type,
         parser->input_pos
     );
     
     // Store token value
     if (token.value) {
         terminal->data = strdup(token.value);
     }
 }
 ```
 
 **Example: Shifting NUMBER token**
 
 Input: `42 + 3`
 
 When the parser shifts `42`:
 
 ```
 Terminal Node:
   type: GLR_NODE_TERMINAL
   symbol_id: NUMBER
   position: 0
   data: "42"
   children: NULL
 ```
 
 ### 4.3.2 On Reduce: Creating Non-Terminal and Constructor Nodes
 
 When the parser reduces by a production, it creates a non-terminal node and a constructor node:
 
 ```c
 void handle_reduce(glr_parser_t *parser, glr_stack_t *stack, int production_id) {
     // Get the production
     glr_production_t *prod = glr_grammar_get_production(parser->grammar, production_id);
     
     // Pop states from stack (one per body symbol)
     glr_forest_node_t **body_nodes = malloc(prod->body_length * sizeof(glr_forest_node_t *));
     for (size_t i = prod->body_length; i > 0; i--) {
         body_nodes[i - 1] = (glr_forest_node_t *)glr_stack_pop(stack);
     }
     
     // Create constructor node
     glr_forest_node_t *constructor = glr_forest_get_node(
         parser->forest,
         GLR_NODE_CONSTRUCTOR,
         production_id,
         parser->input_pos
     );
     
     // Add body nodes as children
     for (size_t i = 0; i < prod->body_length; i++) {
         glr_forest_add_child(constructor, body_nodes[i]);
     }
     
     // Create or get non-terminal node
     glr_forest_node_t *nonterminal = glr_forest_get_node(
         parser->forest,
         GLR_NODE_NONTERMINAL,
         prod->head->id,
         parser->input_pos
     );
     
     // Add constructor as child of non-terminal
     glr_forest_add_child(nonterminal, constructor);
     
     // Push non-terminal onto stack
     glr_stack_push(stack, nonterminal);
     
     // Push goto state
     int goto_state = lookup_goto(parser->parse_table, 
                                   (int)(intptr_t)glr_stack_peek(stack), 
                                   prod->head->id);
     glr_stack_push(stack, (void *)(intptr_t)goto_state);
     
     free(body_nodes);
 }
 ```
 
 **Example: Reducing `factor → NUMBER`**
 
 After shifting `42`, the parser reduces by `factor → NUMBER`:
 
 ```
 Constructor Node:
   type: GLR_NODE_CONSTRUCTOR
   symbol_id: production_id (factor → NUMBER)
   position: 0
   children: [Terminal(NUMBER, "42")]
 
 Non-Terminal Node:
   type: GLR_NODE_NONTERMINAL
   symbol_id: factor
   position: 0
   children: [Constructor(factor → NUMBER)]
 ```
 
 ### 4.3.3 Sharing Nodes
 
 The key to SPPF efficiency is node sharing. When multiple parse paths create the same node (same type, symbol, and position), they share a single node instance:
 
 ```c
 glr_forest_node_t *glr_forest_get_node(glr_forest_t *forest,
                                        glr_forest_node_type_t type,
                                        int symbol_id,
                                        size_t position) {
     // Check if node already exists
     glr_forest_node_t *existing = find_node(forest, type, symbol_id, position);
     if (existing) {
         return existing; // Reuse existing node
     }
     
     // Create new node
     glr_forest_node_t *node = malloc(sizeof(glr_forest_node_t));
     node->type = type;
     node->symbol_id = symbol_id;
     node->position = position;
     node->children = NULL;
     node->child_count = 0;
     node->capacity = 0;
     node->data = NULL;
     node->next = NULL;
     
     // Add to forest
     add_node_to_forest(forest, node, position);
     
     return node;
 }
 ```
 
 ## 4.4 Handling Ambiguity with Packed Nodes
 
 ### 4.4.1 Multiple Derivations
 
 When multiple parse paths produce the same non-terminal at the same position, the SPPF creates a **packed node** by adding multiple constructor children:
 
 ```c
 // First derivation: expr → expr + term
 glr_forest_node_t *constructor1 = create_constructor(prod1, children1);
 glr_forest_add_child(expr_node, constructor1);
 
 // Second derivation: expr → term
 glr_forest_node_t *constructor2 = create_constructor(prod2, children2);
 glr_forest_add_child(expr_node, constructor2);
 
 // Now expr_node has two children, representing two parse trees
 ```
 
 ### 4.4.2 Example: Ambiguous Expression
 
 Consider parsing `1 + 2 * 3` with the ambiguous grammar:
 
 ```
 E → E + E
 E → E * E
 E → number
 ```
 
 The SPPF for this input looks like:
 
 ```
 E[0,5]  (non-terminal at position 5)
   ├─ Constructor: E → E + E
   │    ├─ E[0,1] (1)
   │    ├─ +
   │    └─ E[1,5]
   │         └─ Constructor: E → E * E
   │              ├─ E[1,3] (2)
   │              ├─ *
   │              └─ E[3,5] (3)
   │
   └─ Constructor: E → E * E
        ├─ E[0,3]
        │    └─ Constructor: E → E + E
        │         ├─ E[0,1] (1)
        │         ├─ +
        │         └─ E[1,3] (2)
        ├─ *
        └─ E[3,5] (3)
 ```
 
 The root node `E[0,5]` has two constructor children, representing the two parse trees:
 
 1. `(1 + 2) * 3` - multiply has higher precedence
 2. `1 + (2 * 3)` - addition has higher precedence
 
 ### 4.4.3 Counting Parse Trees
 
 The number of parse trees in an SPPF can be computed recursively:
 
 ```c
 size_t count_parse_trees(glr_forest_node_t *node) {
     if (node == NULL) {
         return 0;
     }
     
     if (node->type == GLR_NODE_TERMINAL) {
         return 1; // Terminal has one tree
     }
     
     if (node->type == GLR_NODE_NONTERMINAL) {
         // Non-terminal: sum trees from all constructor children
         size_t total = 0;
         for (size_t i = 0; i < node->child_count; i++) {
             total += count_parse_trees(node->children[i]);
         }
         return total;
     }
     
     if (node->type == GLR_NODE_CONSTRUCTOR) {
         // Constructor: product of trees from all body children
         size_t product = 1;
         for (size_t i = 0; i < node->child_count; i++) {
             product *= count_parse_trees(node->children[i]);
         }
         return product;
     }
     
     return 0;
 }
 ```
 
 **Example:**
 
 For `1 + 2 * 3` with the ambiguous grammar:
 
 ```c
 glr_forest_node_t *root = get_root_node(forest);
 size_t num_trees = count_parse_trees(root);
 printf("Number of parse trees: %zu\n", num_trees); // Output: 2
 ```
 
 ## 4.5 Extracting Parse Trees
 
 ### 4.5.1 Enumerating All Trees
 
 To extract all parse trees from an SPPF, we traverse the forest and expand all alternatives:
 
 ```c
 typedef struct {
     glr_forest_node_t **nodes;
     size_t count;
 } parse_tree_t;
 
 void extract_trees(glr_forest_node_t *node, parse_tree_t ***trees, size_t *tree_count) {
     if (node->type == GLR_NODE_TERMINAL) {
         // Base case: terminal node
         parse_tree_t *tree = malloc(sizeof(parse_tree_t));
         tree->nodes = malloc(sizeof(glr_forest_node_t *));
         tree->nodes[0] = node;
         tree->count = 1;
         
         *trees = realloc(*trees, (*tree_count + 1) * sizeof(parse_tree_t *));
         (*trees)[*tree_count] = tree;
         (*tree_count)++;
         return;
     }
     
     if (node->type == GLR_NODE_NONTERMINAL) {
         // Non-terminal: extract trees from each constructor child
         for (size_t i = 0; i < node->child_count; i++) {
             extract_trees(node->children[i], trees, tree_count);
         }
         return;
     }
     
     if (node->type == GLR_NODE_CONSTRUCTOR) {
         // Constructor: combine trees from all body children
         parse_tree_t ***child_trees = malloc(node->child_count * sizeof(parse_tree_t **));
         size_t *child_counts = calloc(node->child_count, sizeof(size_t));
         
         // Extract trees from each child
         for (size_t i = 0; i < node->child_count; i++) {
             child_trees[i] = NULL;
             extract_trees(node->children[i], &child_trees[i], &child_counts[i]);
         }
         
         // Compute Cartesian product
         size_t total_combinations = 1;
         for (size_t i = 0; i < node->child_count; i++) {
             total_combinations *= child_counts[i];
         }
         
         // Generate all combinations
         for (size_t combo = 0; combo < total_combinations; combo++) {
             parse_tree_t *tree = malloc(sizeof(parse_tree_t));
             tree->count = node->child_count;
             tree->nodes = malloc(node->child_count * sizeof(glr_forest_node_t *));
             
             size_t temp = combo;
             for (size_t i = 0; i < node->child_count; i++) {
                 size_t index = temp % child_counts[i];
                 temp /= child_counts[i];
                 tree->nodes[i] = child_trees[i][index]->nodes[0];
             }
             
             *trees = realloc(*trees, (*tree_count + 1) * sizeof(parse_tree_t *));
             (*trees)[*tree_count] = tree;
             (*tree_count)++;
         }
         
         // Cleanup
         for (size_t i = 0; i < node->child_count; i++) {
             for (size_t j = 0; j < child_counts[i]; j++) {
                 free(child_trees[i][j]->nodes);
                 free(child_trees[i][j]);
             }
             free(child_trees[i]);
         }
         free(child_trees);
         free(child_counts);
     }
 }
 ```
 
 ### 4.5.2 Extracting a Single Tree
 
 Often, we only need one parse tree (e.g., after disambiguation). We can extract a single tree by choosing one alternative at each ambiguity point:
 
 ```c
 glr_forest_node_t *extract_single_tree(glr_forest_node_t *node) {
     if (node->type == GLR_NODE_TERMINAL) {
         return node; // Terminal is already a tree
     }
     
     if (node->type == GLR_NODE_NONTERMINAL) {
         // Choose first constructor (or use disambiguation strategy)
         if (node->child_count > 0) {
             return extract_single_tree(node->children[0]);
         }
         return NULL;
     }
     
     if (node->type == GLR_NODE_CONSTRUCTOR) {
         // Recursively extract from children
         for (size_t i = 0; i < node->child_count; i++) {
             node->children[i] = extract_single_tree(node->children[i]);
         }
         return node;
     }
     
     return NULL;
 }
 ```
 
 ## 4.6 Forest Traversal
 
 ### 4.6.1 Depth-First Traversal
 
 ```c
 void traverse_forest_dfs(glr_forest_node_t *node, void (*visit)(glr_forest_node_t *)) {
     if (node == NULL) return;
     
     visit(node);
     
     for (size_t i = 0; i < node->child_count; i++) {
         traverse_forest_dfs(node->children[i], visit);
     }
 }
 
 // Example visitor
 void print_node(glr_forest_node_t *node) {
     const char *type_str = (node->type == GLR_NODE_TERMINAL) ? "TERM" :
                            (node->type == GLR_NODE_NONTERMINAL) ? "NONTERM" : "CONS";
     printf("%s[%d] at pos %zu\n", type_str, node->symbol_id, node->position);
 }
 
 // Usage
 traverse_forest_dfs(root, print_node);
 ```
 
 ### 4.6.2 Breadth-First Traversal
 
 ```c
 void traverse_forest_bfs(glr_forest_node_t *node, void (*visit)(glr_forest_node_t *)) {
     if (node == NULL) return;
     
     // Use a queue
     glr_forest_node_t **queue = malloc(1000 * sizeof(glr_forest_node_t *));
     size_t head = 0, tail = 0;
     
     queue[tail++] = node;
     
     while (head < tail) {
         glr_forest_node_t *current = queue[head++];
         visit(current);
         
         for (size_t i = 0; i < current->child_count; i++) {
             queue[tail++] = current->children[i];
         }
     }
     
     free(queue);
 }
 ```
 
 ## 4.7 Forest Merging for Incremental Parsing
 
 ### 4.7.1 The Merging Problem
 
 When editing a file, we don't want to reparse the entire input. Instead, we can:
 
 1. Keep the parse forest for unchanged regions
 2. Reparse only the changed region
 3. Merge the three forests (prefix, changed, suffix)
 
 LibGLR provides `glr_forest_merge()` in `include/glr/forest-merge.h`:
 
 ```c
 int glr_forest_merge(glr_parser_t *parser,
                      const glr_forest_t *left,
                      const glr_forest_t *middle,
                      const glr_forest_t *right,
                      glr_forest_t **out);
 ```
 
 ### 4.7.2 Position Adjustment
 
 When text is inserted or deleted, positions in the suffix forest need adjustment:
 
 ```c
 int glr_forest_adjust_positions(glr_forest_t *forest,
                                  size_t start_pos,
                                  ssize_t delta);
 ```
 
 **Example: Inserting text**
 
 Original: `int x = 42;`
 Edit: Insert ` + 1` at position 10
 Result: `int x = 42 + 1;`
 
 ```c
 // Parse the original
 glr_parse_result_t result1 = glr_parse(parser, "int x = 42;", 11);
 glr_forest_t *original_forest = result1.forest;
 
 // Determine edit range
 size_t edit_start = 10;
 size_t edit_end = 10;
 size_t insert_length = 4; // " + 1"
 
 // Split forest into three parts
 glr_forest_t *left = extract_forest_range(original_forest, 0, edit_start);
 glr_forest_t *right = extract_forest_range(original_forest, edit_end, 11);
 
 // Adjust positions in right forest
 glr_forest_adjust_positions(right, edit_end, insert_length);
 
 // Parse the changed region
 glr_parse_result_t result2 = glr_parse(parser, "42 + 1", 6);
 glr_forest_t *middle = result2.forest;
 
 // Merge
 glr_forest_t *merged = NULL;
 glr_forest_merge(parser, left, middle, right, &merged);
 
 // Now merged contains the complete parse for "int x = 42 + 1;"
 ```
 
 ### 4.7.3 Merging Algorithm
 
 The merging algorithm:
 
 1. Copy all nodes from the left forest
 2. Copy all nodes from the middle forest, adjusting positions
 3. Copy all nodes from the right forest, adjusting positions
 4. Connect edges between the three regions
 5. Resolve any conflicts at boundaries
 
 ## 4.8 Forest Visualization
 
 ### 4.8.1 Printing the Forest
 
 ```c
 void print_forest(glr_forest_node_t *node, int indent) {
     if (node == NULL) return;
     
     for (int i = 0; i < indent; i++) printf("  ");
     
     if (node->type == GLR_NODE_TERMINAL) {
         printf("TERM[%d] \"%s\" at %zu\n", 
                node->symbol_id, 
                (char *)node->data, 
                node->position);
     } else if (node->type == GLR_NODE_NONTERMINAL) {
         printf("NONTERM[%d] at %zu (%zu alternatives)\n", 
                node->symbol_id, 
                node->position, 
                node->child_count);
         for (size_t i = 0; i < node->child_count; i++) {
             print_forest(node->children[i], indent + 1);
         }
     } else if (node->type == GLR_NODE_CONSTRUCTOR) {
         printf("CONS[prod %d] at %zu\n", 
                node->symbol_id, 
                node->position);
         for (size_t i = 0; i < node->child_count; i++) {
             print_forest(node->children[i], indent + 1);
         }
     }
 }
 ```
 
 ### 4.8.2 Exporting to DOT Format
 
 For visualization with Graphviz:
 
 ```c
 void export_forest_dot(glr_forest_node_t *node, FILE *fp) {
     fprintf(fp, "digraph forest {\n");
     fprintf(fp, "  node [shape=box];\n");
     export_forest_dot_recursive(node, fp, 0);
     fprintf(fp, "}\n");
 }
 
 int export_forest_dot_recursive(glr_forest_node_t *node, FILE *fp, int *counter) {
     if (node == NULL) return -1;
     
     int node_id = (*counter)++;
     
     const char *type_str = (node->type == GLR_NODE_TERMINAL) ? "TERM" :
                            (node->type == GLR_NODE_NONTERMINAL) ? "NONTERM" : "CONS";
     
     fprintf(fp, "  n%d [label=\"%s[%d]@%zu\"];\n", 
             node_id, type_str, node->symbol_id, node->position);
     
     for (size_t i = 0; i < node->child_count; i++) {
         int child_id = export_forest_dot_recursive(node->children[i], fp, counter);
         if (child_id >= 0) {
             fprintf(fp, "  n%d -> n%d;\n", node_id, child_id);
         }
     }
     
     return node_id;
 }
 
 // Usage
 FILE *fp = fopen("forest.dot", "w");
 export_forest_dot(root, fp);
 fclose(fp);
 
 // Then: dot -Tpng forest.dot -o forest.png
 ```
 
 ## 4.9 Performance Considerations
 
 ### 4.9.1 Space Complexity
 
 The SPPF has worst-case space complexity of $O(n^3)$ for highly ambiguous grammars, where $n$ is the input length. In practice:
 
 - **Unambiguous grammars**: $O(n)$ space
 - **Limited ambiguity**: $O(n^2)$ space
 - **Highly ambiguous**: $O(n^3)$ space
 
 ### 4.9.2 Node Sharing
 
 Aggressive node sharing is critical for performance. The `glr_forest_get_node()` function should use a hash table to quickly find existing nodes:
 
 ```c
 typedef struct {
     glr_forest_node_type_t type;
     int symbol_id;
     size_t position;
 } node_key_t;
 
 // Hash function
 size_t hash_node_key(node_key_t *key) {
     return (key->type * 31 + key->symbol_id) * 31 + key->position;
 }
 
 // Lookup in hash table
 glr_forest_node_t *find_node(glr_forest_t *forest, node_key_t *key) {
     size_t hash = hash_node_key(key);
     // ... hash table lookup ...
 }
 ```
 
 ### 4.9.3 Memory Management
 
 Forest nodes can consume significant memory. Strategies to reduce usage:
 
 - **Lazy tree extraction**: Don't extract all trees; extract on demand
 - **Pruning**: Remove unlikely alternatives during parsing (Chapter 7)
 - **Garbage collection**: Remove unreachable nodes after disambiguation
 
 ## 4.10 Summary
 
 This chapter covered the SPPF and forest construction:
 
 - The SPPF uses three node types: terminal, non-terminal, and constructor
 - Nodes are shared across parse trees to save space
 - Ambiguity is represented by packed nodes with multiple children
 - Parse trees can be extracted by traversing the forest
 - Forest merging enables incremental parsing
 
 Key takeaways:
 
 - Use `glr_forest_get_node()` to create or retrieve nodes
 - Use `glr_forest_add_child()` to build the tree structure
 - Count parse trees with recursive traversal
 - Extract trees by expanding alternatives
 - Merge forests for incremental parsing with `glr_forest_merge()`
 
 The next chapter explores grammar representation and loading in detail.
