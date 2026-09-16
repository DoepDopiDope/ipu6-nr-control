CXX ?= g++
CPPFLAGS ?=
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Werror
LDFLAGS ?= -shared -fPIC -Wl,-z,now
LDLIBS ?= -Wl,--no-as-needed -l:libcamhal.so.0 -Wl,--as-needed

BUILD_DIR := build
TARGET := $(BUILD_DIR)/libcameranoise.so
SOURCE := src/cameranoise.cpp

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(SOURCE)
	mkdir -p $(BUILD_DIR)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(LDFLAGS) -o $@ $< $(LDLIBS)

test:
	./tests/run-tests.sh

clean:
	rm -rf -- $(BUILD_DIR)
