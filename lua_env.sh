#!/usr/bin/env bash
# Local, self-contained Lua toolchain (like a Python venv), installed in ./.lua
#
#   source lua_env.sh init     # build Lua + LuaRocks + busted + luacheck + stylua (needs cc, make, curl, unzip)
#   source lua_env.sh active   # put ./.lua/bin on PATH for the current shell
#
# Lua 5.5 is built from the official tarball because yazi embeds Lua 5.5 and
# hererocks does not support it yet.

LUA_VERSION="5.5.1"
LUAROCKS_VERSION="3.13.0"
STYLUA_VERSION="2.6.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LUA_DIR="${SCRIPT_DIR}/.lua"
BUILD_DIR="${SCRIPT_DIR}/tmp/build"

_lua_env_init() {
    set -e
    rm -rf "${LUA_DIR}" && mkdir -p "${BUILD_DIR}" && cd "${BUILD_DIR}"

    echo "--> Building Lua ${LUA_VERSION}"
    curl -fsSLO "https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz"
    tar xzf "lua-${LUA_VERSION}.tar.gz"
    local platform; platform="$([[ "$(uname)" == Darwin ]] && echo macosx || echo linux)"
    (cd "lua-${LUA_VERSION}" && make "${platform}" -j4 >/dev/null && make install INSTALL_TOP="${LUA_DIR}" >/dev/null)

    echo "--> Building LuaRocks ${LUAROCKS_VERSION}"
    curl -fsSLO "https://luarocks.org/releases/luarocks-${LUAROCKS_VERSION}.tar.gz"
    tar xzf "luarocks-${LUAROCKS_VERSION}.tar.gz"
    (cd "luarocks-${LUAROCKS_VERSION}" \
        && ./configure --prefix="${LUA_DIR}" --with-lua="${LUA_DIR}" >/dev/null \
        && make >/dev/null && make install >/dev/null)

    export PATH="${LUA_DIR}/bin:${PATH}"
    echo "--> Installing rocks (busted, luacheck)"
    luarocks install busted >/dev/null
    luarocks install luacheck >/dev/null
    # luacheck 1.2.0 assigns to a for-loop variable, which is a compile error in Lua 5.5.
    sed -i.bak 's/^   for field_name, field_def in pairs(fields) do$/   for loop_name, loop_def in pairs(fields) do\n      local field_name, field_def = loop_name, loop_def/' \
        "${LUA_DIR}/share/lua/5.5/luacheck/standards.lua" && rm -f "${LUA_DIR}/share/lua/5.5/luacheck/standards.lua.bak"

    echo "--> Installing stylua ${STYLUA_VERSION}"
    local asset; asset="$([[ "$(uname)" == Darwin ]] && echo macos-aarch64 || echo linux-x86_64)"
    curl -fsSLo stylua.zip "https://github.com/JohnnyMorganz/StyLua/releases/download/v${STYLUA_VERSION}/stylua-${asset}.zip"
    unzip -oq stylua.zip -d "${LUA_DIR}/bin" && chmod +x "${LUA_DIR}/bin/stylua"
    echo "--> Done."
}

case "$1" in
    init)   (_lua_env_init) && export PATH="${LUA_DIR}/bin:${PATH}" ;;
    active) export PATH="${LUA_DIR}/bin:${PATH}"; lua -v ;;
    *)      echo "Usage: source lua_env.sh [init|active]" ;;
esac
