 # Chapter 9: Incremental Parsing and Caching
 
 ## 9.1 Overview
 
 Incremental parsing re-parses only the changed portions of input after edits. LibGLR provides caching (`include/glr/cache.h`) and diffing (`include/glr/diff.h`) for efficient incremental updates.
 
 ## 9.2 Cache Structure
 
 From `include/glr/cache.h`:
 
 ```c
 typedef struct glr_cache_t glr_cache_t;
 
 typedef struct {
     size_t start_pos;
     size_t end_pos;
     glr_forest_t *forest;
     uint64_t hash;
 } glr_cache_entry_t;
 
 typedef struct {
     size_t hits;
     size_t misses;
     size_t evictions;
     size_t total_entries;
 } glr_cache_stats_t;
 ```
 
 ## 9.3 Using the Cache
 
 ```c
 // Create cache
 glr_cache_t *cache = glr_cache_create(1024); // 1024 entries
 
 // Parse with caching
 glr_parser_set_cache(parser, cache);
 glr_parse_result_t result = glr_parse(parser, input, length);
 
 // Edit input
 const char *new_input = "int x = 43;"; // Changed 42 to 43
 
 // Reparse (uses cache for unchanged regions)
 result = glr_parse(parser, new_input, strlen(new_input));
 
 // Check cache statistics
 glr_cache_stats_t stats;
 glr_cache_get_stats(cache, &stats);
 printf("Cache hits: %zu, misses: %zu\n", stats.hits, stats.misses);
 
 // Cleanup
 glr_cache_destroy(cache);
 ```
 
 ## 9.4 Diff-Based Incremental Parsing
 
 From `include/glr/diff.h`:
 
 ```c
 typedef struct {
     size_t start;
     size_t old_length;
     size_t new_length;
     const char *new_text;
 } glr_diff_edit_t;
 
 // Compute diff
 glr_diff_edit_t edit = {
     .start = 10,
     .old_length = 2,  // "42"
     .new_length = 2,  // "43"
     .new_text = "43"
 };
 
 // Apply incremental parse
 glr_forest_t *new_forest = glr_parse_incremental(
     parser, 
     old_forest, 
     &edit
 );
 ```
 
 ## 9.5 Forest Merging
 
 From `include/glr/forest-merge.h`:
 
 ```c
 // Split forest at edit boundaries
 glr_forest_t *left = extract_forest_range(old_forest, 0, edit.start);
 glr_forest_t *right = extract_forest_range(old_forest, edit.start + edit.old_length, input_length);
 
 // Adjust positions in right forest
 glr_forest_adjust_positions(right, edit.start + edit.old_length, 
                              edit.new_length - edit.old_length);
 
 // Parse changed region
 glr_parse_result_t middle_result = glr_parse(parser, edit.new_text, edit.new_length);
 
 // Merge three forests
 glr_forest_t *merged = NULL;
 glr_forest_merge(parser, left, middle_result.forest, right, &merged);
 ```
 
 ## 9.6 Dependency Tracking
 
 From `include/glr/dependency.h`:
 
 ```c
 typedef struct {
     size_t start_pos;
     size_t end_pos;
     glr_forest_node_t *node;
 } glr_dependency_t;
 
 // Track which forest nodes depend on which input ranges
 glr_dependency_t *deps = glr_compute_dependencies(forest);
 
 // When editing [10, 12), invalidate dependent nodes
 invalidate_dependencies(deps, 10, 12);
 ```
 
 ## 9.7 Complete Incremental Parsing Example
 
 ```c
 #include <glr/glr.h>
 
 int main(void) {
     glr_grammar_t *grammar = glr_grammar_load("c.grammar");
     glr_parser_t *parser = glr_parser_create(grammar);
     glr_cache_t *cache = glr_cache_create(1024);
     glr_parser_set_cache(parser, cache);
     
     // Initial parse
     const char *input1 = "int x = 42;";
     glr_parse_result_t result1 = glr_parse(parser, input1, strlen(input1));
     glr_forest_t *forest1 = result1.forest;
     
     // Edit: change 42 to 43
     const char *input2 = "int x = 43;";
     glr_diff_edit_t edit = {
         .start = 8,
         .old_length = 2,
         .new_length = 2,
         .new_text = "43"
     };
     
     // Incremental parse
     glr_forest_t *forest2 = glr_parse_incremental(parser, forest1, &edit);
     
     // Check cache stats
     glr_cache_stats_t stats;
     glr_cache_get_stats(cache, &stats);
     printf("Cache hits: %zu (reused unchanged regions)\n", stats.hits);
     
     // Cleanup
     glr_forest_destroy(forest2);
     glr_cache_destroy(cache);
     glr_parser_destroy(parser);
     glr_grammar_destroy(grammar);
     
     return 0;
 }
 ```
 
 ## 9.8 Summary
 
 - Incremental parsing reparses only changed regions
 - Caching stores parse results for reuse
 - Diffing identifies changed regions
 - Forest merging combines unchanged and reparsed regions
 - Dependency tracking invalidates affected nodes
