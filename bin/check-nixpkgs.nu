#!/usr/bin/env nu
# Check nixpkgs and conda-forge availability and upstream drift for all git submodules.
# Run from the repository root: nu bin/check-nixpkgs.nu
# Upstream drift columns require the GitHub CLI (gh) to be installed and authenticated.

# Known nixpkgs package names that differ from the submodule directory name.
let nix_aliases = {
    bdwgc:                "boehmgc"
    boost-multiprecision: "boost"
    boost-preprocessor:   "boost"
}

# Known conda-forge package names that differ from the submodule directory name.
let conda_aliases = {
    bdwgc:                "boehmgc"
    boost-multiprecision: "boost-cpp"
    boost-preprocessor:   "boost-cpp"
    boost-process:        "boost-cpp"
    cppinterop:           "cppinterop"
}

# Fetch the latest version of a package from nixpkgs-unstable.
# The canonical search UI is https://search.nixos.org/packages?query=<name> but it is a
# JavaScript SPA whose Elasticsearch backend requires authentication, so we use
# lazamar.co.uk which mirrors the same nixpkgs data as static, parseable HTML.
def nixpkgs-latest [name: string] {
    let url = $"https://lazamar.co.uk/nix-versions/?package=($name)&channel=nixpkgs-unstable"
    let html = try { http get $url } catch { return {version: "fetch error", found: false} }
    if ($html | str contains "No results found") {
        {version: "—", found: false}
    } else {
        # Each table row has (version, date, …) cells — all digit-leading.
        # Exclude YYYY-MM-DD date cells; lazamar lists oldest-first so take last.
        let versions = (
            $html
            | parse --regex '<td[^>]*>(?P<v>[0-9][^<]*)</td>'
            | get v
            | each { str trim }
            | where { |v| $v !~ '^\d{4}-\d{2}-\d{2}' }
        )
        let latest = if ($versions | is-empty) { "?" } else { $versions | last }
        {version: $latest, found: true}
    }
}

# Fetch the latest version of a package from conda-forge via the Anaconda.org API.
def conda-latest [name: string] {
    let url = $"https://api.anaconda.org/package/conda-forge/($name)"
    let resp = try { http get $url } catch { return {version: "—", found: false} }
    let version = $resp | get latest_version?
    if $version == null {
        {version: "—", found: false}
    } else {
        {version: $version, found: true}
    }
}

# Date of the commit the submodule is currently pinned to (local git, no network).
def pinned-date [path: string, hash: string] {
    try {
        ^git -C $path log -1 --format="%ci" $hash
        | str trim
        | split row " "
        | first
    } catch { "—" }
}

# How far the fork's pinned commit has drifted from upstream in both directions.
# Returns a record {upstream, fork} where:
#   upstream = commits in upstream's HEAD not in the pin (how far behind jank is)
#   fork     = commits in the pin not in upstream's HEAD (jank's custom patches)
# Runs the compare against the fork repo using a cross-repo base (owner:branch) so
# it works even when the pinned commit is jank-specific and not in the upstream.
# Uses the GitHub API via gh CLI; returns "—" when gh is unavailable or the repo
# has no upstream parent, and "?" on transient API errors.
def upstream-drift [url: string, hash: string] {
    let none = {upstream: "—", fork: "—"}
    let repo = $url
        | str replace -r '^https://github\.com/' ""
        | str replace -r '\.git$' ""

    # Use `complete` to capture stderr so gh error messages don't leak to the terminal.
    let r1 = ^gh api $"/repos/($repo)" | complete
    if $r1.exit_code != 0 { return $none }

    let repo_info = $r1.stdout | from json
    let parent = $repo_info | get parent?
    if $parent == null { return $none }

    # Cross-repo compare: base is upstream's HEAD, head is jank's pinned commit.
    # ahead_by  = pin commits not in upstream (jank's changes)
    # behind_by = upstream commits not in pin (upstream drift)
    let parent_owner = $parent.full_name | split row "/" | first
    let base = $"($parent_owner):($parent.default_branch)"

    let r2 = ^gh api $"/repos/($repo)/compare/($base)...($hash)" | complete
    if $r2.exit_code != 0 { return {upstream: "?", fork: "?"} }

    let cmp = $r2.stdout | from json
    {
        upstream: ($cmp.behind_by | into string),
        fork:     ($cmp.ahead_by  | into string),
    }
}

def main [
    --markdown (-m)  # Emit a Markdown table instead of the default nushell table
    --drift (-d)     # Include upstream/fork commit-drift columns (requires gh auth)
    --conda (-c)     # Include conda-forge latest-version column
] {
    # Pinned commit hashes from git submodule status.
    let status = (
        ^git submodule status
        | lines
        | each { |l|
            let r = (
                $l | str trim
                | parse --regex '^[-+U ]?(?P<hash>[0-9a-f]+) (?P<path>[^ ]+)'
                | first
            )
            {path: $r.path, name: ($r.path | path basename), hash: $r.hash}
        }
    )

    # URLs from .gitmodules, keyed by submodule path.
    let urls = (
        ^git config --file .gitmodules --get-regexp "submodule\\..*\\.url"
        | lines
        | each { |l|
            let kv   = $l | split row " "
            let path = ($kv | get 0) | parse "submodule.{p}.url" | first | get p
            {path: $path, url: ($kv | last)}
        }
    )

    let gh_ok = $drift and (which gh | is-not-empty)

    let results = (
        $status | par-each { |s|
            let url_rows = $urls | where path == $s.path
            let url = if ($url_rows | is-not-empty) { $url_rows | first | get url } else { "" }

            let nix_name = $nix_aliases   | get -o $s.name | default $s.name
            let nixpkgs  = nixpkgs-latest $nix_name
            let date     = pinned-date $s.path $s.hash
            let d = if $gh_ok and ($url | str contains "github.com") {
                upstream-drift $url $s.hash
            } else {
                {upstream: "—", fork: "—"}
            }

            let base = {
                submodule:                $s.name,
                "pinned date":            $date,
                "upstream ahead of fork": $d.upstream,
                "fork ahead of upstream": $d.fork,
                "nixpkgs name":           (if $nixpkgs.found { $nix_name } else { "—" }),
                "nixpkgs version":        $nixpkgs.version,
            }

            if $conda {
                let cn = $conda_aliases | get -o $s.name | default $s.name
                let cr = conda-latest $cn
                $base | merge {
                    "conda-forge name":    (if $cr.found { $cn } else { "—" }),
                    "conda-forge version": $cr.version,
                }
            } else {
                $base
            }
        }
        | sort-by submodule
    )

    if $markdown { $results | to md --pretty } else { $results }
}
