cmake_minimum_required(VERSION 3.21)
project(fx570ex VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_INCLUDE_CURRENT_DIR ON)

include(GNUInstallDirs)
include(CTest)

find_package(Qt6 REQUIRED COMPONENTS Widgets)

set(FX570EX_CORE
    src/core/Exact.cpp
    src/core/Value.cpp
    src/core/Node.cpp
    src/core/Parser.cpp
    src/core/Eval.cpp
    src/core/Format.cpp
    src/core/Engine.cpp
)

add_executable(fx570ex
    src/main.cpp
    ${FX570EX_CORE}
    src/ui/NaturalRender.cpp
    src/ui/DisplayWidget.cpp
    src/ui/KeyButton.cpp
    src/ui/CalculatorWindow.cpp
)
target_include_directories(fx570ex PRIVATE src)
target_link_libraries(fx570ex PRIVATE Qt6::Widgets)

install(TARGETS fx570ex RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

# The self-test drives the same Engine the keypad does, so it needs QtCore only
# and runs without a display -- which is what makes it usable as a Nix
# checkPhase.
if(BUILD_TESTING)
    add_executable(fx570ex_selftest tests/selftest.cpp ${FX570EX_CORE})
    target_include_directories(fx570ex_selftest PRIVATE src)
    target_link_libraries(fx570ex_selftest PRIVATE Qt6::Core)
    add_test(NAME selftest COMMAND fx570ex_selftest)
endif()
