# Makefile for installing Lua
# See doc/readme.html for installation and customization instructions.

# == CHANGE THE SETTINGS BELOW TO SUIT YOUR ENVIRONMENT =======================

# Your platform. See PLATS for possible values.
PLAT= none

# Where to install. The installation starts in the src and doc directories,
# so take care if INSTALL_TOP is not an absolute path. See the local target.
# You may want to make INSTALL_LMOD and INSTALL_CMOD consistent with
# LUA_ROOT, LUA_LDIR, and LUA_CDIR in luaconf.h.
INSTALL_TOP= /usr/local
INSTALL_BIN= $(INSTALL_TOP)/bin
INSTALL_INC= $(INSTALL_TOP)/include
INSTALL_LIB= $(INSTALL_TOP)/lib
INSTALL_MAN= $(INSTALL_TOP)/man/man1
INSTALL_LMOD= $(INSTALL_TOP)/share/lua/$V
INSTALL_CMOD= $(INSTALL_TOP)/lib/lua/$V

# How to install. If your install program does not support "-p", then
# you may have to run ranlib on the installed liblua.a.
INSTALL= install -p
INSTALL_EXEC= $(INSTALL) -m 0755
INSTALL_DATA= $(INSTALL) -m 0644
#
# If you don't have "install" you can use "cp" instead.
# INSTALL= cp -p
# INSTALL_EXEC= $(INSTALL)
# INSTALL_DATA= $(INSTALL)

# Other utilities.
MKDIR= mkdir -p
RM= rm -f

# == END OF USER SETTINGS -- NO NEED TO CHANGE ANYTHING BELOW THIS LINE =======

# Convenience platforms targets.
PLATS= aix bsd c89 freebsd generic linux macosx mingw posix solaris

# What to install.
TO_BIN= lua luac
TO_INC= lua.h luaconf.h lualib.h lauxlib.h lua.hpp
TO_LIB= liblua.a
TO_MAN= lua.1 luac.1

# Lua version and release.
V= 5.3
R= $V.4

# Targets start here.
all:	$(PLAT)

$(PLATS) clean:
	cd src && $(MAKE) $@

test:	dummy
	src/lua -v

# Language / stdlib e2e (excludes GC fuzz; see tests/test_gc_fuzz.lua)
test-e2e:	dummy
	src/lua tests/e2e/run_all.lua

# Optional bare-userdata helper for GC fuzz (ignored by git as *.so)
tests/t_udata.so: tests/t_udata.c src/lua.h src/lauxlib.h
	gcc -std=gnu99 -O2 -fPIC -Isrc -shared -o $@ tests/t_udata.c

test-udata: tests/t_udata.so

# Official PUC-Lua 5.3.4 testes (fetch first: scripts/fetch_testes.sh)
test-testes-basic:	dummy
	@test -f testes/all.lua || { echo "missing testes/; run scripts/fetch_testes.sh"; exit 1; }
	cd testes && ../src/lua -e'_U=true' all.lua

test-testes:	dummy
	@test -f testes/all.lua || { echo "missing testes/; run scripts/fetch_testes.sh"; exit 1; }
	@test -f src/lua || { echo "build interpreter first (e.g. make linux)"; exit 1; }
	cd testes/libs && $(MAKE) LUA_DIR=../../src
	cd testes && ../src/lua -e'_port=true' all.lua

install: dummy
	cd src && $(MKDIR) $(INSTALL_BIN) $(INSTALL_INC) $(INSTALL_LIB) $(INSTALL_MAN) $(INSTALL_LMOD) $(INSTALL_CMOD)
	cd src && $(INSTALL_EXEC) $(TO_BIN) $(INSTALL_BIN)
	cd src && $(INSTALL_DATA) $(TO_INC) $(INSTALL_INC)
	cd src && $(INSTALL_DATA) $(TO_LIB) $(INSTALL_LIB)
	cd doc && $(INSTALL_DATA) $(TO_MAN) $(INSTALL_MAN)

uninstall:
	cd src && cd $(INSTALL_BIN) && $(RM) $(TO_BIN)
	cd src && cd $(INSTALL_INC) && $(RM) $(TO_INC)
	cd src && cd $(INSTALL_LIB) && $(RM) $(TO_LIB)
	cd doc && cd $(INSTALL_MAN) && $(RM) $(TO_MAN)

local:
	$(MAKE) install INSTALL_TOP=../install

none:
	@echo "Please do 'make PLATFORM' where PLATFORM is one of these:"
	@echo "   $(PLATS)"
	@echo "See doc/readme.html for complete instructions."

# make may get confused with test/ and install/
dummy:

# echo config parameters
echo:
	@cd src && $(MAKE) -s echo
	@echo "PLAT= $(PLAT)"
	@echo "V= $V"
	@echo "R= $R"
	@echo "TO_BIN= $(TO_BIN)"
	@echo "TO_INC= $(TO_INC)"
	@echo "TO_LIB= $(TO_LIB)"
	@echo "TO_MAN= $(TO_MAN)"
	@echo "INSTALL_TOP= $(INSTALL_TOP)"
	@echo "INSTALL_BIN= $(INSTALL_BIN)"
	@echo "INSTALL_INC= $(INSTALL_INC)"
	@echo "INSTALL_LIB= $(INSTALL_LIB)"
	@echo "INSTALL_MAN= $(INSTALL_MAN)"
	@echo "INSTALL_LMOD= $(INSTALL_LMOD)"
	@echo "INSTALL_CMOD= $(INSTALL_CMOD)"
	@echo "INSTALL_EXEC= $(INSTALL_EXEC)"
	@echo "INSTALL_DATA= $(INSTALL_DATA)"

# echo pkg-config data
pc:
	@echo "version=$R"
	@echo "prefix=$(INSTALL_TOP)"
	@echo "libdir=$(INSTALL_LIB)"
	@echo "includedir=$(INSTALL_INC)"

# list targets that do not create files (but not all makes understand .PHONY)
.PHONY: all $(PLATS) clean test test-e2e test-udata test-testes-basic test-testes install local none dummy echo pecho lecho

# (end of Makefile)
