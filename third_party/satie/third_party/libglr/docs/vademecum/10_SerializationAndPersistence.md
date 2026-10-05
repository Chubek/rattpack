 # Chapter 10: Serialization and Persistence
 
 ## 10.1 Overview
 
 LibGLR provides serialization (`include/glr/serialization.h`) for persisting parse forests, grammars, and parse tables to disk.
 
 ## 10.2 Serialization Format
 
 From `include/glr/serialization.h`:
 
 ```c
 typedef struct __attribute__((packed)) {
     uint32_t magic;      // 0x474C5246 ("GLRF")
     uint32_t version;    // Format version
     uint64_t node_count;
     uint64_t edge_count;
 } glr_forest_header_t;
 
 typedef struct __attribute__((packed)) {
     uint32_t type;       // Node type
     int32_t symbol_id;
     uint64_t position;
     uint64_t child_count;
 } glr_forest_node_header_t;
 
 typedef struct __attribute__((packed)) {
     uint32_t magic;      // 0x474C5247 ("GLRG")
     uint32_t version;
     uint64_t symbol_count;
     uint64_t production_count;
 } glr_grammar_header_t;
 ```
 
 ## 10.3 Serializing Forests
 
 ```c
 // Serialize to file
 int glr_forest_serialize(glr_forest_t *forest, const char *filename) {
     FILE *fp = fopen(filename, "wb");
     if (!fp) return -1;
     
     // Write header
     glr_forest_header_t header = {
         .magic = 0x474C5246,
         .version = 1,
         .node_count = forest->node_count,
         .edge_count = forest->edge_count
     };
     fwrite(&header, sizeof(header), 1, fp);
     
     // Write nodes
     for (size_t i = 0; i < forest->node_count; i++) {
         serialize_node(forest->nodes[i], fp);
     }
     
     // Write edges
     for (size_t i = 0; i < forest->edge_count; i++) {
         serialize_edge(forest->edges[i], fp);
     }
     
     fclose(fp);
     return 0;
 }
 
 // Deserialize from file
 glr_forest_t *glr_forest_deserialize(const char *filename) {
     FILE *fp = fopen(filename, "rb");
     if (!fp) return NULL;
     
     // Read header
     glr_forest_header_t header;
     fread(&header, sizeof(header), 1, fp);
     
     if (header.magic != 0x474C5246) {
         fclose(fp);
         return NULL;
     }
     
     // Create forest
     glr_forest_t *forest = glr_forest_create();
     
     // Read nodes
     for (size_t i = 0; i < header.node_count; i++) {
         glr_forest_node_t *node = deserialize_node(fp);
         add_node_to_forest(forest, node, i);
     }
     
     // Read edges
     for (size_t i = 0; i < header.edge_count; i++) {
         glr_forest_edge_t *edge = deserialize_edge(fp);
         glr_forest_add_edge(forest, edge);
     }
     
     fclose(fp);
     return forest;
 }
 ```
 
 ## 10.4 Serializing Grammars
 
 ```c
 // Serialize grammar
 int glr_grammar_serialize(glr_grammar_t *grammar, const char *filename);
 
 // Deserialize grammar
 glr_grammar_t *glr_grammar_deserialize(const char *filename);
 
 // Usage
 glr_grammar_serialize(grammar, "grammar.glrg");
 glr_grammar_t *loaded = glr_grammar_deserialize("grammar.glrg");
 ```
 
 ## 10.5 Serializing Parse Tables
 
 ```c
 // Serialize parse table
 int glr_parse_table_serialize(glr_parse_table_t *table, const char *filename);
 
 // Deserialize parse table
 glr_parse_table_t *glr_parse_table_deserialize(const char *filename);
 
 // Usage
 glr_parse_table_serialize(table, "table.glrt");
 glr_parse_table_t *loaded = glr_parse_table_deserialize("table.glrt");
 ```
 
 ## 10.6 Binary Format Details
 
 The binary format uses little-endian byte order and packed structures:
 
 - **Magic numbers** identify file types
 - **Version numbers** enable format evolution
 - **Counts** precede variable-length arrays
 - **Strings** are length-prefixed
 
 ## 10.7 Complete Example
 
 ```c
 #include <glr/glr.h>
 
 int main(void) {
     // Parse input
     glr_grammar_t *grammar = glr_grammar_load("c.grammar");
     glr_parser_t *parser = glr_parser_create(grammar);
     glr_parse_result_t result = glr_parse(parser, "int x = 42;", 11);
     
     // Serialize forest
     glr_forest_serialize(result.forest, "parse.glrf");
     
     // Serialize grammar
     glr_grammar_serialize(grammar, "grammar.glrg");
     
     // Later: deserialize
     glr_forest_t *loaded_forest = glr_forest_deserialize("parse.glrf");
     glr_grammar_t *loaded_grammar = glr_grammar_deserialize("grammar.glrg");
     
     // Use loaded data
     size_t tree_count = count_parse_trees(loaded_forest);
     printf("Loaded forest has %zu parse trees\n", tree_count);
     
     // Cleanup
     glr_forest_destroy(loaded_forest);
     glr_grammar_destroy(loaded_grammar);
     glr_parser_destroy(parser);
     glr_grammar_destroy(grammar);
     
     return 0;
 }
 ```
 
 ## 10.8 Summary
 
 - Serialization persists parse forests, grammars, and parse tables
 - Binary format uses magic numbers and version tags
 - Enables caching of parse results across sessions
 - Useful for build systems and incremental compilation
