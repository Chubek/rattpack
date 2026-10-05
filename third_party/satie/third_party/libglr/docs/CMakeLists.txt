cmake_minimum_required(VERSION 3.16)

project(LibGLRDocs
    VERSION 0.1.0
    DESCRIPTION "Doxygen documentation build"
    LANGUAGES NONE
)

# -----------------------------------------------------------------------------
# Options
# -----------------------------------------------------------------------------

option(ENABLE_DOXYGEN "Build documentation with Doxygen" ON)


# -----------------------------------------------------------------------------
# Find Directories
# -----------------------------------------------------------------------------

set(LibGLR_TOP_SRCDIR "${CMAKE_SOURCE_DIR}")

# -----------------------------------------------------------------------------
# Find Doxygen
# -----------------------------------------------------------------------------

if(ENABLE_DOXYGEN)
    find_package(Doxygen REQUIRED)
endif()

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------

set(LibGLR_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/docs)
set(LibGLR_LAYOUT_FILE ${CMAKE_CURRENT_SOURCE_DIR}/layout.xml)
set(LibGLR_STRIP_FROM_INC_PATH ${CMAKE_CURRENT_SOURCE_DIR})
set(LibGLR_WARN_LOGFILE ${CMAKE_CURRENT_BINARY_DIR}/doxygen.warn)

# Graphviz (dot)
find_program(DOT_EXECUTABLE dot)
if(DOT_EXECUTABLE)
    set(LibGLR_HAVE_DOT YES)
else()
    set(LibGLR_HAVE_DOT NO)
endif()

# -----------------------------------------------------------------------------
# Configure Doxyfile
# -----------------------------------------------------------------------------

set(DOXYFILE_IN  ${CMAKE_CURRENT_SOURCE_DIR}/Doxyfile.in)
set(DOXYFILE_OUT ${CMAKE_CURRENT_BINARY_DIR}/Doxyfile)

configure_file(
    ${DOXYFILE_IN}
    ${DOXYFILE_OUT}
    @ONLY
)

# -----------------------------------------------------------------------------
# Docs target
# -----------------------------------------------------------------------------

if(ENABLE_DOXYGEN)
    add_custom_target(docs
        COMMAND ${DOXYGEN_EXECUTABLE} ${DOXYFILE_OUT}
        WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
        COMMENT "Generating API documentation with Doxygen"
        VERBATIM
    )
endif()

# -----------------------------------------------------------------------------
# Convenience targets
# -----------------------------------------------------------------------------

add_custom_target(docs-clean
    COMMAND ${CMAKE_COMMAND} -E rm -rf ${LibGLR_OUTPUT_DIRECTORY}
    COMMENT "Removing generated documentation"
)

