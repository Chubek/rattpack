 # Chapter 1: Introduction to LibGLR
 
 ## 1.1 What is LibGLR?
 
 LibGLR is a comprehensive C library for implementing **Generalized LR (GLR) parsers**. It is part of the TwinBooks project and provides a complete toolkit for parsing ambiguous context-free grammars. Unlike traditional LR parsers that fail on ambiguous grammars, GLR parsers can handle multiple parse paths simultaneously, making them ideal for:
 
 - Natural language processing
 - Programming languages with ambiguous syntax
 - Domain-specific languages (DSLs)
 - Legacy code analysis
 - Syntax highlighting and IDE tooling
 
 LibGLR implements the modern GLR algorithm with optimizations including:
 
 - **Graph-Structured Stack (GSS)**: Efficient representation of multiple parser states
 - **Shared Packed Parse Forest (SPPF)**: Compact representation of all possible parse trees
 - **Disambiguation strategies**: Configurable policies for selecting preferred parses
 - **Incremental parsing**: Support for efficient re-parsing after edits
 - **Grammar rewriting**: Tools for transforming grammars into more efficient forms
 
 ## 1.2 Historical Context: From LR to GLR
 
 ### 1.2.1 LR Parsing
 
 LR parsing, introduced by Donald Knuth in 1965, is a bottom-up parsing technique that builds parse trees from leaves to root. An LR parser uses:
 
 - A **parse table** with ACTION and GOTO entries
 - A **stack** to track parser states
 - A **lookahead** token to decide the next action
 
 LR parsers are deterministic and efficient ($O(n)$ time complexity), but they require the grammar to be unambiguous and LR-compatible. Many practical grammars fail this requirement.
 
 ### 1.2.2 The Birth of GLR
 
 In 1985, **Masaru Tomita** introduced Generalized LR parsing to handle ambiguous grammars. Tomita's key insight was to allow the parser to **fork** when faced with conflicts:
 
 - **Shift-reduce conflicts**: Both shift and reduce actions are valid
 - **Reduce-reduce conflicts**: Multiple reductions are possible
 
 Instead of choosing one action, a GLR parser pursues all possibilities in parallel. This is achieved through:
 
 1. **Graph-Structured Stack (GSS)**: Instead of a linear stack, the parser maintains a directed acyclic graph (DAG) of states. Each path through the GSS represents a possible parse.
 
 2. **Shared Packed Parse Forest (SPPF)**: Instead of a single parse tree, the parser builds a compact graph that encodes all possible parse trees. Shared nodes represent common subtrees.
 
 ### 1.2.3 Modern GLR Implementations
 
 Since Tomita's original work, GLR parsing has evolved significantly:
 
 - **Right-Nulled GLR (RNGLR)**: Handles nullable productions more efficiently
 - **Binary SPPF (BSPPF)**: Ensures the SPPF has bounded node degree
 - **Incremental GLR**: Supports efficient re-parsing after edits
 - **Scannerless GLR (SGLR)**: Integrates lexing and parsing
 
 Modern tools like **TreeSitter** use GLR-inspired techniques for incremental parsing in code editors. LibGLR provides a traditional GLR implementation with modern optimizations.
 
 ## 1.3 Core Concepts
 
 ### 1.3.1 Context-Free Grammars
 
 A context-free grammar (CFG) is a 4-tuple $G = (N, \Sigma, P, S)$ where:
 
 - $N$ is a finite set of **non-terminal symbols**
 - $\Sigma$ is a finite set of **terminal symbols** (tokens)
 - $P$ is a finite set of **production rules** of the form $A \rightarrow \alpha$ where $A \in N$ and $\alpha \in (N \cup \Sigma)^*$
 - $S \in N$ is the **start symbol**
 
 Example grammar for arithmetic expressions:
 
 ```
 E → E + E
 E → E * E
 E → ( E )
 E → number
 ```
 
 This grammar is **ambiguous** because the string `1 + 2 * 3` has two parse trees depending on operator precedence.
 
 ### 1.3.2 LR Parse Tables
 
 An LR parser uses two tables:
 
 - **ACTION table**: Indexed by (state, terminal), contains shift, reduce, accept, or error actions
 - **GOTO table**: Indexed by (state, non-terminal), contains the next state after a reduction
 
 For GLR parsing, conflicts in the ACTION table are not errors—they trigger forking.
 
 ### 1.3.3 Graph-Structured Stack (GSS)
 
 The GSS is a directed acyclic graph where:
 
 - **Nodes** represent parser states
 - **Edges** are labeled with grammar symbols
 - **Paths** from the root to a node represent possible stack configurations
 
 When the parser forks, it creates multiple paths in the GSS. Paths can merge when they reach the same state, sharing computation.
 
 ### 1.3.4 Shared Packed Parse Forest (SPPF)
 
 The SPPF is a directed acyclic graph that compactly represents all parse trees:
 
 - **Symbol nodes**: Represent grammar symbols at specific input positions
 - **Packed nodes**: Represent alternative derivations (ambiguity points)
 - **Intermediate nodes**: Represent partial productions
 
 The SPPF allows efficient storage of exponentially many parse trees in polynomial space.
 
 ## 1.4 LibGLR Architecture Overview
 
 LibGLR is organized into several modules, each handling a specific aspect of GLR parsing:
 
 ### Core Parsing Modules
 
 - **`glr.h`**: Main header that includes all other modules
 - **`parser.h`**: Core parser infrastructure and main parsing loop
 - **`stack.h`**: GSS implementation with DAG-based stack operations
 - **`fork.h`**: Forking mechanism for handling conflicts
 - **`reduction.h`**: Reduction operations and semantic actions
 
 ### Data Structure Modules
 
 - **`grammar.h`**: Grammar representation (symbols, productions, parse tables)
 - **`forest.h`**: SPPF construction and manipulation
 - **`forest-merge.h`**: Merging operations for SPPF nodes
 - **`graph.h`**: Generic graph operations used by GSS and SPPF
 
 ### Input/Output Modules
 
 - **`reader.h`**: Token stream abstraction for input
 - **`lexer-hooks.h`**: Hooks for integrating custom lexers
 - **`serialization.h`**: Serialization and deserialization of parse forests
 
 ### Advanced Features
 
 - **`disambiguate.h`**: Disambiguation strategies for selecting preferred parses
 - **`rewrite.h`**: Grammar rewriting and transformation
 - **`cache.h`**: Caching for incremental parsing
 - **`diff.h`**: Diffing for efficient re-parsing
 - **`dependency.h`**: Dependency tracking for incremental updates
 
 ## 1.5 Getting Started with LibGLR
 
 ### 1.5.1 Installation
 
 LibGLR uses CMake for building:
 
 ```bash
 mkdir build && cd build
 cmake ..
 make
 sudo make install
 ```
 
 This installs:
 - Header files in `/usr/local/include/glr/`
 - Library files in `/usr/local/lib/`
 - Documentation in `/usr/local/share/doc/libglr/`
 
 ### 1.5.2 Basic Usage Pattern
 
 A typical LibGLR program follows this pattern:
 
 ```c
 #include <glr/glr.h>
 
 int main(void) {
     // 1. Load or define a grammar
     glr_grammar_t *grammar = glr_grammar_load("grammar.txt");
     
     // 2. Create a parser instance
     glr_parser_t *parser = glr_parser_create(grammar);
     
     // 3. Set up input (token stream)
     glr_reader_t *reader = glr_reader_create_from_file("input.txt");
     
     // 4. Parse the input
     glr_forest_t *forest = glr_parse(parser, reader);
     
     // 5. Disambiguate if needed
     glr_tree_t *tree = glr_disambiguate(forest, GLR_DISAMBIG_PRECEDENCE);
     
     // 6. Process the parse tree
     process_tree(tree);
     
     // 7. Clean up
     glr_tree_destroy(tree);
     glr_forest_destroy(forest);
     glr_reader_destroy(reader);
     glr_parser_destroy(parser);
     glr_grammar_destroy(grammar);
     
     return 0;
 }
 ```
 
 ### 1.5.3 Key API Functions
 
 LibGLR provides a clean C API. Here are the most important functions you'll use:
 
 **Grammar Management:**
 ```c
 glr_grammar_t *glr_grammar_load(const char *filename);
 glr_grammar_t *glr_grammar_create(void);
 void glr_grammar_destroy(glr_grammar_t *grammar);
 ```
 
 **Parser Creation:**
 ```c
 glr_parser_t *glr_parser_create(glr_grammar_t *grammar);
 void glr_parser_destroy(glr_parser_t *parser);
 ```
 
 **Parsing:**
 ```c
 glr_forest_t *glr_parse(glr_parser_t *parser, glr_reader_t *reader);
 ```
 
 **Disambiguation:**
 ```c
 glr_tree_t *glr_disambiguate(glr_forest_t *forest, glr_disambig_policy_t policy);
 ```
 
 ## 1.6 A Simple Example: Arithmetic Expressions
 
 Let's build a complete example that parses arithmetic expressions.
 
 ### Grammar Definition (expr.grammar)
 
 ```
 %token NUMBER
 %token PLUS MINUS TIMES DIVIDE
 %token LPAREN RPAREN
 
 %start expr
 
 %%
 
 expr : expr PLUS term
      | expr MINUS term
      | term
      ;
 
 term : term TIMES factor
      | term DIVIDE factor
      | factor
      ;
 
 factor : NUMBER
        | LPAREN expr RPAREN
        ;
 ```
 
 ### Parser Implementation (expr_parser.c)
 
 ```c
 #include <stdio.h>
 #include <stdlib.h>
 #include <glr/glr.h>
 
 // Simple lexer that tokenizes arithmetic expressions
 typedef struct {
     const char *input;
     size_t pos;
 } simple_lexer_t;
 
 glr_token_t next_token(simple_lexer_t *lexer) {
     glr_token_t token = {0};
     
     // Skip whitespace
     while (lexer->input[lexer->pos] == ' ' || 
            lexer->input[lexer->pos] == '\t') {
         lexer->pos++;
     }
     
     char c = lexer->input[lexer->pos];
     
     if (c == '\0') {
         token.type = GLR_TOKEN_EOF;
         return token;
     }
     
     token.start = lexer->pos;
     
     if (c >= '0' && c <= '9') {
         // Number
         while (lexer->input[lexer->pos] >= '0' && 
                lexer->input[lexer->pos] <= '9') {
             lexer->pos++;
         }
         token.type = NUMBER;
         token.length = lexer->pos - token.start;
     } else {
         // Operator or parenthesis
         lexer->pos++;
         token.length = 1;
         
         switch (c) {
             case '+': token.type = PLUS; break;
             case '-': token.type = MINUS; break;
             case '*': token.type = TIMES; break;
             case '/': token.type = DIVIDE; break;
             case '(': token.type = LPAREN; break;
             case ')': token.type = RPAREN; break;
             default:
                 token.type = GLR_TOKEN_ERROR;
         }
     }
     
     return token;
 }
 
 int main(int argc, char **argv) {
     if (argc != 2) {
         fprintf(stderr, "Usage: %s <expression>\n", argv[0]);
         return 1;
     }
     
     // Load grammar
     glr_grammar_t *grammar = glr_grammar_load("expr.grammar");
     if (!grammar) {
         fprintf(stderr, "Failed to load grammar\n");
         return 1;
     }
     
     // Create parser
     glr_parser_t *parser = glr_parser_create(grammar);
     
     // Set up lexer
     simple_lexer_t lexer = { .input = argv[1], .pos = 0 };
     
     // Create reader from lexer
     glr_reader_t *reader = glr_reader_create_from_callback(
         (glr_token_callback_t)next_token, &lexer
     );
     
     // Parse
     printf("Parsing: %s\n", argv[1]);
     glr_forest_t *forest = glr_parse(parser, reader);
     
     if (!forest) {
         fprintf(stderr, "Parse failed\n");
         return 1;
     }
     
     // Check for ambiguity
     size_t num_trees = glr_forest_count_trees(forest);
     printf("Number of parse trees: %zu\n", num_trees);
     
     if (num_trees > 1) {
         printf("Grammar is ambiguous! Disambiguating...\n");
         
         // Use precedence-based disambiguation
         glr_tree_t *tree = glr_disambiguate(forest, GLR_DISAMBIG_PRECEDENCE);
         
         printf("Selected parse tree:\n");
         glr_tree_print(tree, stdout);
         
         glr_tree_destroy(tree);
     } else {
         printf("Grammar is unambiguous.\n");
         glr_tree_t *tree = glr_forest_get_tree(forest, 0);
         glr_tree_print(tree, stdout);
         glr_tree_destroy(tree);
     }
     
     // Clean up
     glr_forest_destroy(forest);
     glr_reader_destroy(reader);
     glr_parser_destroy(parser);
     glr_grammar_destroy(grammar);
     
     return 0;
 }
 ```
 
 ### Building and Running
 
 ```bash
 gcc -o expr_parser expr_parser.c -lglr
 ./expr_parser "1 + 2 * 3"
 ```
 
 Output:
 ```
 Parsing: 1 + 2 * 3
 Number of parse trees: 2
 Grammar is ambiguous! Disambiguating...
 Selected parse tree:
   expr
     expr
       term
         factor
           NUMBER[1]
     PLUS
     term
       term
         factor
           NUMBER[2]
       TIMES
       factor
         NUMBER[3]
 ```
 
 This example demonstrates:
 - Loading a grammar from a file
 - Creating a custom lexer
 - Parsing input with potential ambiguity
 - Detecting and resolving ambiguity
 - Extracting and printing the parse tree
 
 ## 1.7 What's Next?
 
 This chapter introduced the fundamentals of GLR parsing and LibGLR's architecture. The remaining chapters will dive deep into each component:
 
 - **Chapter 2**: Core data structures (GSS, SPPF, grammars)
 - **Chapter 3**: Parser implementation and stack management
 - **Chapter 4**: Forest construction and manipulation
 - **Chapter 5**: Grammar representation and loading
 - **Chapter 6**: Lexical analysis and input handling
 - **Chapter 7**: Disambiguation strategies
 - **Chapter 8**: Grammar rewriting and transformation
 - **Chapter 9**: Incremental parsing and caching
 - **Chapter 10**: Serialization and persistence
 - **Chapter 11**: Advanced topics and integration
 - **Chapter 12**: Complete case study building an ANSI C parser
 
 Each chapter includes detailed explanations, code examples, and practical guidance for using LibGLR effectively.
