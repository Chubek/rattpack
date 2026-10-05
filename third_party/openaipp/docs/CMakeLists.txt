# docs/CMakeLists.txt
# Builds documentation for OpenAIpp using Doxygen and EZDox.

# --- Doxygen ---
find_package(Doxygen QUIET)

if(Doxygen_FOUND)
  set(DOXYGEN_INPUT_DIR ${CMAKE_SOURCE_DIR}/include)
  set(DOXYGEN_OUTPUT_DIR ${CMAKE_CURRENT_BINARY_DIR}/doxygen)

  configure_file(${CMAKE_CURRENT_SOURCE_DIR}/Doxyfile.in
                 ${CMAKE_CURRENT_BINARY_DIR}/Doxyfile
                 @ONLY)

  add_custom_target(
    doxygen
    COMMAND ${DOXYGEN_EXECUTABLE} ${CMAKE_CURRENT_BINARY_DIR}/Doxyfile
    WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
    COMMENT "Generating Doxygen documentation"
    VERBATIM
  )

  add_custom_target(
    doxygen_clean
    COMMAND ${CMAKE_COMMAND} -E remove_directory ${DOXYGEN_OUTPUT_DIR}
    COMMENT "Cleaning Doxygen output"
    VERBATIM
  )
else()
  message(WARNING "Doxygen not found; 'doxygen' target will not be available")
endif()

# --- EZDox ---
find_program(EZDOX_CLI ezdox-cli)

if(EZDOX_CLI)
  set(EZDOX_CONFIG ${CMAKE_CURRENT_SOURCE_DIR}/EZDox.yaml)
  set(EZDOX_OUTPUT_DIR ${CMAKE_CURRENT_BINARY_DIR}/ezdox)

  add_custom_target(
    ezdox
    COMMAND ${EZDOX_CLI} generate -C ${EZDOX_CONFIG} -O ${EZDOX_OUTPUT_DIR} --clean
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Generating EZDox documentation"
    VERBATIM
  )

  add_custom_target(
    ezdox_clean
    COMMAND ${CMAKE_COMMAND} -E remove_directory ${EZDOX_OUTPUT_DIR}
    COMMENT "Cleaning EZDox output"
    VERBATIM
  )
else()
  message(WARNING "ezdox-cli not found; 'ezdox' target will not be available")
endif()

# --- Aggregate docs target ---
if(Doxygen_FOUND OR EZDOX_CLI)
  add_custom_target(docs)

  if(Doxygen_FOUND)
    add_dependencies(docs doxygen)
  endif()

  if(EZDOX_CLI)
    add_dependencies(docs ezdox)
  endif()
endif()
