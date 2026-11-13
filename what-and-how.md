# The what and how of Zcaml

> [!NOTE]
> 1. Completely written by me no LLM involved here so there will be typos and mistakes please forgive me and feel free to point them out.
> 2. I am still very new to the ocaml world so I could be completely incorrect about things, would love to get feedback on what I got wrong.


The general idea is to make it seamless to build and cross compile ocaml projects with some help from zig.

[Chris Armstrong](https://bsky.app/profile/chrisarmstrong.link) has discussed about [this in the past](https://discuss.ocaml.org/t/early-work-experimenting-with-zig-as-a-cross-compiler-for-ocaml/16151) and [this blog](https://www.chrisarmstrong.dev/posts/ocaml-cross-compilation-an-experiment) where he builds ocaml with zig as the c compiler similar to how opam-cross-windows works. This is a more "blessed" way of doing things and uses the existing configure and make scripts from ocaml itself. This is basically where i started as well but then i ran into a bunch of problems (detailed below) so i had to completely rethink how it works. I will try to contrast both of our approaches and explain my reasoning for why i did it the way i did.

> From now on i will refer to Chris and his experiment as he/him and his approach (or similar)

---

I will split this into 3 parts of the puzzle:
1. Ocaml toolchain
2. The build system
3. Opam and the ecosystem

## Ocaml toolchain

My first instinct was to do what he did to star but immediately ran into a whole bunch of problems because of how the build system is setup There are several things within this so I will try to keep this terse but please feel free to ask more questions about any part.

1. The major problem i ran into is the build, host and target machine separation. Upstream does have a make crossopt thingy but it assumes (some because of real constraints most compilers have and some just assumptions of the regular kind :)) For example it assumes the build machine and the host machine are the same. This means i can't build a toolchain whose build machine is `A`, runs on `B` and targets `C`. This is usually called canadian cross (for reasons unknown to me lol). This was a huge deal breaker for me as i wanted to be able to build ocaml for an arbitrary host target pair from any build machine irrespective of the host machine.

2. Several parts of the build process take facts about the build machine and bake them into the toolchain. For example the bytecode launcher bakes in /usr/bin/sh from my machine as the shell which would break on a darwin or windows machine where the shell lives somewhere else or is not present at all.

3. The configure script runs a lot of test programs for feature detection to bake in facts about the compiler like existance of fma, printf etc. This makes `1` impossible cuz the test programs would fail to run on `A` because they were built for `B`. The script works around this by guessing or reusing cached values but...its just that guessing.

4. **Windows** was another huge pain. Flexlink expects a mingw gcc toolchain and expects to know all the c symbols the c toolchain gives so it can do its thing. Which is a problem because zig crt lazily builds things on demand so we have to workaround that part to make zig give Flexlink what it wants.

There are other minor things like the compiler baking in absolute build paths inot the debug info and stuff which i had to strip and turn into relative paths, per target weirdness with clang and other small incompatibilities etc etc.

So for these reasons i just started from scratch and hand ported all of the things that configure and make do into the zig build system. This immediately fixed almost all of my problmes mentioned above as zig ships with libcs for all targets and metadata about them so we can deterministically generate all the things configure had to build test programs for without any of that (some cases I baked in empirical values derived from running the test programs on targets using the zig provided libs so the build machine need not run them). so `1`, `2` and `3` are immediately solved. `4` I found workarounds for and made them work without much trouble.

Then i had a build setup that can build from any machine that cna run zig to build ocaml for any (host, target) pair. **Which i do by building [97 different toolchains in CI targetting various (host, target, libc) combinations from a single linux machine here](https://github.com/zcaml/zcaml/actions/runs/42987500813)**

> His version in contrast does 2 builds one for host and one for target to generate the right config values with a shell script which is a lot simpler than what i did but hits a lot of the gcc vs clang edge cases, posix or binutils assumptions etc the configure assumes.

## Dune and Opam

This is where the biggest difference comes in. In his version he uses stock dune and opam and add a new tool packman that rewrites the packages to change what they are called and uses heuristics to determine host machine builds vs target machine builds and adds the right -x and --toolchain flags. This means the user has to do more work to keep re mapping package names, keep versions in sync etc.

What i did is patch dune itself to make a new context and build each package for both of them. default and default.{toolchain} and utilizes the dune pkg bult in cross compilation support so users dont have to deal with mapping package names or anything else. When a package build tries to run dune exec we swithc the ocaml path env to point to the host machine so things like ppx and like work. We set the right environment variables for findlib conf to pickup our ocaml paths.

One caveat with my approach is that the project must use dune pkg which is not as widely used as opam.

## The ecosystem

I like to split this problem part further into 2 parts
1. Portable builds: Many opam packages just expect a posix shell, binutils, gcc etc to exist and work as expected which makes it incredibly difficult when any of those assumptions arent met on the users' machine and that breaks the build. One of the many reasons why windows is often a pain to work with in the ocaml world.

2. Cross builds: Related to the first but this one is more of a problem with c libraries than ocaml itself. The problem is many packages do configure and make during builds which runs on the host machine and fails when linking or other steps that mix host and target blobs. Another problem is many packages also link with "common" system libraries which will not be available for cross target builds and thus break the build.

So I created an overlay for all the common opam packages to 1. trun everything into protable dune only scripts and 2. build new packages that make it easy to build libraries like openssl, libz, zstd, gmp, libpq etc by making it easier for dune and ocaml to be able to build them from source using the findlib paths and the c compiler for that target (which is a zig cc wrapper in both of our cases).

Most of this work is not specific to zcaml and can be upstreamed so the overlay package can slowly be removed and directly consume the upstream.
