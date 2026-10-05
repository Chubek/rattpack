find_package(Doxygen)

if(NOT Doxygen_FOUND)
    message(STATUS "Doxygen not found; docs target will be unavailable")
    return()
endif()

set(NUPERF_DOCS_OUTPUT_DIR ${CMAKE_CURRENT_BINARY_DIR}/html)
set(NUPERF_DOCS_WARN_LOG ${CMAKE_CURRENT_BINARY_DIR}/doxygen.warn)
set(NUPERF_DOCS_LAYOUT_FILE ${CMAKE_CURRENT_SOURCE_DIR}/layout.xml)
set(NUPERF_DOCS_STRIP_FROM_PATH ${CMAKE_SOURCE_DIR})

find_program(DOT_EXECUTABLE dot)
if(DOT_EXECUTABLE)
    set(NUPERF_HAVE_DOT YES)
else()
    set(NUPERF_HAVE_DOT NO)
endif()

configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/Doxyfile.in
    ${CMAKE_CURRENT_BINARY_DIR}/Doxyfile
    @ONLY
)

add_custom_target(docs
    COMMAND ${DOXYGEN_EXECUTABLE} ${CMAKE_CURRENT_BINARY_DIR}/Doxyfile
    WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
    COMMENT "Generating NuPERF documentation"
    VERBATIM
)

if(NUPERF_INSTALL_DOCS)
    install(DIRECTORY ${NUPERF_DOCS_OUTPUT_DIR}/
        DESTINATION ${CMAKE_INSTALL_DATADIR}/doc/nuperf
        OPTIONAL
    )
endif()
