import Foundation
import MarkdownKit

// Independent conformance suite: realistic mini documents (README, changelog, notes, blog post, tech docs).
// These check that ordinary writing is not mis-styled; every document is also exercised by the real-corpus runner.

func runSpecRealWorld() {
    specGroupStart("real-world")
    let J = SpecKind.judge
    let S = SpecKind.spec

    let readme = """
    # my_project

    [![Build](https://img.shields.io/badge/build-passing-green.svg)](https://ci.example.com/my_project) [![npm](https://img.shields.io/npm/v/my_pkg.svg)](https://npm.example.com/my_pkg)

    > **Note**
    > This is a note with `code_span`.

    ## Install

    ```sh
    npm install --save my_package_name
    ```

    ## Usage

    1. First step: run `foo_bar --flag`.
    2. Second step: edit `my_config.yml`:

       ```yaml
       key: value
       other_key: [1, 2]
       ```

    3. Third step.

    | Option | Default | Description |
    |--------|---------|-------------|
    | `--foo_bar` | `true` | Enables foo_bar. |
    | `-v` | `false` | Verbose; see [docs](https://example.com/docs_v2/index.html). |

    See https://example.com/a_b_c and the file some_dir/some_file.txt.

    ---

    Licensed under MIT. Contact first_last@example.com or @some_user.
    """
    sh(J, readme, [
        "+h1 my_project", "-italic my_project",
        "+image ![Build](https://img.shields.io/badge/build-passing-green.svg)", "+dest https://ci.example.com/my_project", "+image ![npm]",
        "+q1,bold Note", "+q1,code code_span",
        "+h2 Install", "+codeblock npm install --save my_package_name",
        "+h2 Usage", "+list 1. ", "+code foo_bar --flag", "+list 2. ", "+code my_config.yml",
        "+fence,lang yaml", "+codeblock key: value", "+codeblock other_key: [1, 2]", "+list 3. ", "plain Third step.",
        "+table,thead Option", "+table,tdelim --------", "+code --foo_bar", "+table,code true", "+table Enables foo_bar.", "-italic foo_bar.",
        "+link docs", "+dest https://example.com/docs_v2/index.html",
        "+auto https://example.com/a_b_c", "plain some_dir/some_file.txt", "+hr ---\n", "plain first_last@example.com", "plain @some_user.",
    ])

    let changelog = """
    # Changelog
    All notable changes to this project will be documented in this file.

    ## [Unreleased]

    ## [1.1.0] - 2019-02-15
    ### Added
    - Danish translation from [@frederikspang](https://github.com/frederikspang).
    - Georgian translation from [@tatocaster](https://github.com/tatocaster).
    ### Changed
    - Fix typos in the README.

    [Unreleased]: https://github.com/olivierlacan/keep-a-changelog/compare/v1.1.0...HEAD
    [1.1.0]: https://github.com/olivierlacan/keep-a-changelog/compare/v1.0.0...v1.1.0
    """
    sh(J, changelog, [
        "+h1 Changelog", "plain All notable changes", "+h2 [Unreleased]", "+h2 [1.1.0] - 2019-02-15", "+h3 Added", "+list - @@2", "+link @frederikspang", "+dest https://github.com/frederikspang",
        "+h3 Changed", "+ref Unreleased@@2", "+dest https://github.com/olivierlacan/keep-a-changelog/compare/v1.1.0...HEAD", "+ref 1.1.0@@3", "+dest https://github.com/olivierlacan/keep-a-changelog/compare/v1.0.0...v1.1.0",
    ])

    let blog = """
    ---
    title: "A post: with colon"
    date: 2024-01-02
    tags: [a, b_c]
    ---

    Intro paragraph with a footnote[^1] and *emphasis*, **strong**, and ~~strike~~.
    It continues on a second line with snake_case_name and a_b.

    ## Section _one_

    > A quote that spans
    > two lines.
    >
    > — Someone

    * * *

    Math: $a_i + b_j = c_k$ and $x*y*z$ and the \\_literal\\_ underscores.

    [^1]: The footnote, with `code`.
    """
    sh(J, blog, [
        "+fm title: \"A post: with colon\"", "+fm tags: [a, b_c]", "-italic b_c", "+marker,fm ---", "plain Intro paragraph with a footnote",
        "+fn [^1]", "+italic emphasis", "+bold strong", "+strike strike", "plain snake_case_name and a_b.",
        "+h2 Section ", "+h2,italic one", "+q1 A quote that spans", "+q1 two lines.", "+q1 — Someone", "+hr * * *",
        "plain Math: $a_i + b_j = c_k$", "+esc \\_", "+fn [^1]@@2", "+code code",
    ])

    let notes = """
    # Meeting 2024-05-06

    Attendees: alice_smith, bob_jones, @carol_d
    Tags: #project_x #q2_planning

    - [x] Send agenda to first_last@example.com
    - [ ] Review PR #123 and issue #45
      - [ ] nested *todo*
    - Budget is $5*3*2 = 30 (approx. ~$30)

    TODO: call 555-0100 * 2 and compare a * b * c.

    [[Wiki Link]] and [[Other Page|alias]] and ![[image.png]]

    Done :+1: :smile: ✅
    """
    sh(J, notes, [
        "+h1 Meeting 2024-05-06", "plain Attendees: alice_smith, bob_jones, @carol_d", "plain Tags: #project_x #q2_planning", "+task,checked [x]", "+task [ ]", "plain first_last@example.com",
        "plain Review PR #123", "+italic todo", "plain TODO: call 555-0100 * 2 and compare a * b * c.", "plain [[Wiki Link]] and [[Other Page|alias]]", "plain Done :+1: :smile:",
    ])

    let tech = """
    Setting up
    ==========

    Run the following:

        $ git clone https://example.com/x_y.git
        $ cd x_y

    Then edit `config.ini`:

    ```ini
    [section]
    key = value ; comment *not em*
    # hash comment
    ```

    Options
    -------

    * `-a`, `--all`: do everything
    * `-n`: dry run, see **Notes** below

    Notes
    -----

    1. Use __init__.py only if needed.
    2. The pattern `**/*.js` matches all JS files; src/**/*.ts too.
    """
    sh(J, tech, [
        "+h1 Setting up", "+h1,marker ==========", "+codeblock $ git clone https://example.com/x_y.git", "+codeblock $ cd x_y", "-auto https://example.com/x_y.git", "+code config.ini",
        "+codeblock key = value ; comment *not em*", "+codeblock # hash comment", "-h1 hash comment", "+h2 Options", "+h2,marker -------", "+list * ", "+code -a", "+bold Notes", "+h2 Notes@@2",
        "+bold init", "+code **/*.js", "plain src/**/*.ts too.",
    ])

    // Everyday prose with the typical false-positive hazards, no formatting intended at all.
    spPlain(J, "The quick brown fox jumps over the lazy dog (and, yes, it's 5 * 3 = 15; a_b is fine).\n")
    spPlain(J, "Price: $5 * 3 and 10% of x*y when z_1 and z_2 differ; see item #3 and e.g. foo_bar().\n")
    spPlain(J, "Dear John,\n\nThanks for your mail (re: Q3 numbers - attached). Best,\nAnn\n")
    spPlain(J, "Line one\nline two with a trailing backslash\\\nline three\n")
    spPlain(J, "https_proxy and HTTP_PROXY and no_proxy env vars; $HOME/.config/my_app/settings_v2.json\n")
    spPlain(J, "Use the --dry_run flag or the -v option; set MY_VAR_NAME=1 and my_var_name=2.\n")
    // CommonMark (and GitHub) treat these as raw HTML tags, so they are styled as such: the editor shows what the reader will (not) see
    sx(S, "2020-01-02 14:30 — fixed bug #123 (see PR #124) [WIP] <draft>\n", "[:2020-01-02 14:30 — fixed bug #123 (see PR #124) [WIP] ][html:<draft>][:⏎]")
    sx(S, "if a<b and c>d then x = y * z / w; arr[i] = arr[j] * 2;\n", "[:if a][html:<b and c>][:d then x = y * z / w; arr[i] = arr[j] * 2;⏎]")
    sx(S, "plain *a* b\n", "[:plain ][italic·marker:*][italic:a][italic·marker:*][: b⏎]")
}
