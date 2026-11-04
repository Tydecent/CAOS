#!/usr/bin/env bash
# commands/version.sh — 项目版本、git 信息、工具链版本。支持 --json。
# 用法: ./manage.sh version [--json]

source "$MANAGE_DIR/script/lib/buildroot.sh"

cmd_version_usage() {
    cat <<'EOF'
用法: ./manage.sh version [--json]

输出: crate 版本、git describe/commit/branch/dirty、
      rustc/cargo/make 版本（首行）、Buildroot 版本。
EOF
}

cmd_version() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help) cmd_version_usage; return 0 ;;
            --json)    OPT_JSON=1 ;;
            *)         die 2 "version: 未知参数: $1（--help 查看用法）" ;;
        esac
        shift
    done

    acquire_lock shared

    local version commit branch describe dirty
    version="$(project_version)"; [ -n "$version" ] || version="unknown"
    commit="$(_git_commit)"
    branch="$(_git_branch)"
    describe="$(_git_describe)"
    dirty="$(_git_dirty)"

    local rustc_v cargo_v make_v br_ver
    rustc_v="$(rustc -V 2>/dev/null || true)"
    cargo_v="$(cargo -V 2>/dev/null || true)"
    local make_all
    make_all="$(make -v 2>/dev/null || true)"
    make_v="${make_all%%$'\n'*}"
    [ -n "$rustc_v" ] || rustc_v=unknown
    [ -n "$cargo_v" ] || cargo_v=unknown
    [ -n "$make_v" ]  || make_v=unknown
    br_ver="$(_buildroot_version)"; [ -n "$br_ver" ] || br_ver="unknown"

    if [ "$OPT_JSON" -eq 1 ]; then
        {
            printf '{\n'
            printf '  "version": "%s",\n' "$(json_escape "$version")"
            printf '  "git_describe": "%s",\n' "$(json_escape "$describe")"
            printf '  "commit": "%s",\n' "$(json_escape "$commit")"
            printf '  "branch": "%s",\n' "$(json_escape "$branch")"
            printf '  "dirty": %s,\n' "$dirty"
            printf '  "toolchain": {\n'
            printf '    "rustc": "%s",\n' "$(json_escape "$rustc_v")"
            printf '    "cargo": "%s",\n' "$(json_escape "$cargo_v")"
            printf '    "make": "%s"\n' "$(json_escape "$make_v")"
            printf '  },\n'
            printf '  "buildroot_version": "%s"\n' "$(json_escape "$br_ver")"
            printf '}\n'
        } > /tmp/.caos_version_json
        cat /tmp/.caos_version_json
        rm -f /tmp/.caos_version_json
    else
        log "version:            $version"
        log "git describe:       $describe"
        log "commit:             $commit"
        log "branch:             $branch"
        log "dirty:              $dirty"
        log "rustc:              $rustc_v"
        log "cargo:              $cargo_v"
        log "make:               $make_v"
        log "buildroot version:  $br_ver"
    fi
}
