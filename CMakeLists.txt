cmake_minimum_required(VERSION 3.16)
project(divvygrid)

set(CMAKE_AUTOMOC ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick DBus)
find_package(KF6GlobalAccel REQUIRED)

add_executable(divvygrid main.cpp)
target_link_libraries(divvygrid PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::DBus KF6::GlobalAccel)

# Standalone settings GUI - edits ~/.config/divvygrid/config.json and can
# restart the daemon. Deliberately independent of the divvygrid target above
# (no shared sources) so the two can be built/edited without conflicting.
find_package(Qt6 REQUIRED COMPONENTS Widgets)
add_executable(divvygrid-settings settings/settings_main.cpp)
target_link_libraries(divvygrid-settings PRIVATE Qt6::Core Qt6::Gui Qt6::Widgets)
