# 🌈 📦️ Welcome to the Container and Containerization community! 📦️ 🌈

Contributions to Container and Containerization are welcomed and encouraged.

## Index

- [How you can help](#how-you-can-help)
- [Discussions, Issues, and Pull Requests](#discussions-issues-and-pull-requests)
- [Filing effective bug reports](#filing-effective-bug-reports)
- [New to open source?](#new-to-open-source)
- [AI contribution guidelines](#ai-contribution-guidelines)
- [Code of conduct](#code-of-conduct)

## How you can help

We would love your contributions in the form of:

🐛 Bug fixes\
⚡️ Performance improvements\
✨ API additions or enhancements\
📝 Documentation\
🧑‍💻 Project advocacy: blogs, conference talks, and more

Anything else that could enhance the project!

## Discussions, Issues, and Pull Requests

### Discussions

Use [GitHub Discussions](https://github.com/apple/container/discussions) for early, open-ended, or conceptual conversations — for example, to check whether an idea is directionally aligned with the goals of the project before proposing it as concrete work. Discussions for both container and containerization take place in the container repository.

Once an idea is well-defined enough to act on, open an issue for it and link back to the discussion.

### Issues

To file a bug or feature request, use GitHub issues in the project that owns the behavior:

- [container](https://github.com/apple/container/issues/new) — the `container` CLI and its commands, the API server and system services, container networking and DNS, and image, volume, and builder workflows driven from the CLI.
- [containerization](https://github.com/apple/containerization/issues/new) — the Swift packages (`Containerization`, `ContainerizationOCI`, `ContainerizationEXT4`, and others), `cctl`, `vminitd` and the guest environment, kernel builds, and the Linux (cloud-hypervisor) backend.

If you're not sure which project an issue belongs to, file it in [container](https://github.com/apple/container/issues/new) and maintainers will move it if needed.

🚧 For unexpected behavior or usability limitations, detailed instructions on how to reproduce the issue are appreciated. This will greatly help the priority setting and speed at which maintainers can get to your issue. See [Filing effective bug reports](#filing-effective-bug-reports) for what to include.

### Working on an issue

We ask that you agree on an approach in an issue before writing code. This lets discussion happen early, saves you from reworking a pull request, and increases the chance that your contribution is accepted.

1. **Start from a clear, actionable issue.** If one doesn't exist, create it. It should describe a specific problem or change that someone could pick up and complete — not an open-ended idea (use [Discussions](#discussions) for those).
2. **Indicate that you want to work on it.** Leave a comment on the issue so others know it's being worked on.
3. **Share your plan.** Describe how you intend to make the change — for example, the approach you'll take, the areas of the code involved, any API or behavior changes, and how you'll test it.
4. **Wait for a maintainer to acknowledge your plan** before you start writing code, if the change is non-trivial.

For non-trivial changes, such as new features, API changes, or substantial bug fixes, these steps are required. For small changes, such as typo fixes, documentation updates, or obvious one-line bug fixes, you can open a pull request directly, but we still encourage you to link it to an issue. Pull requests that skip these steps may be deprioritized.

### Pull requests

We require all commits be signed with any of GitHub's supported methods, such as GPG or SSH. Information on how to set this up can be found on [GitHub's docs](https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification#about-commit-signature-verification).

Please give the team a few days to review but it's ok to check in on occasion. We appreciate your contribution!

> [!IMPORTANT]
> If you plan to make substantial changes or add new features, agree on an approach in an issue before you open a pull request.
> See [Working on an issue](#working-on-an-issue) for details.

We use a "squash and merge" strategy to keep our `main` branch history clean and easy to follow. When your pull request
is merged, all of your commits will be combined into a single commit.

With the "squash and merge" strategy, the *title* and *body* of your pull request is extremely important. It will become the commit message
for the squashed commit. Think of it as the single, definitive description of your contribution.

Before merging, we'll review the pull request title and body to ensure it:

* Clearly and concisely describes the changes.
* Uses the imperative mood (for example, "Add feature," "Fix bug").
* Provides enough context for future developers to understand the purpose of the change.

The pull request description should be concise and accurately describe the *what* and *why* of your changes.

#### .gitignore contributions

We do not currently accept contributions to add editor specific additions to the root .gitignore. We urge contributors to make a global .gitignore file with their rulesets they may want to add instead. A global .gitignore file can be set like so:

```bash
git config --global core.excludesfile ~/.gitignore
```

#### Formatting contributions

Make sure your contributions are consistent with the rest of the project's formatting. You can do this using our Makefile:

```bash
make fmt
```

#### Applying license header to new files

If you submit a contribution that adds a new file, please add the license header. You can do this using our Makefile:

```bash
make update-licenses
```

## Filing effective bug reports

This section helps you collect the information maintainers need to reproduce and fix an issue. Complete and accurate reports get resolved faster.

💡 **Example of a good bug report**: [apple/container#1094](https://github.com/apple/container/issues/1094) demonstrates many of the practices described below.

### Steps to reproduce

Clear reproduction steps are the most important part of a bug report.

1. **Starting state**: What was your setup before the issue?
   - Fresh installation or existing setup?
   - Any specific configuration files?
   - Previous commands that led to this state?
   - Has your machine recently been restarted?
2. **Exact commands or code**: Copy-paste the exact commands you ran, including all flags and arguments. If you're using the Containerization packages directly, include a minimal code snippet that reproduces the problem. Use code blocks for clarity.
3. **Reproducibility**: Does it happen every time?
   - Always reproducible
   - Happens sometimes (describe the conditions)
   - Only happened once

For example:

```
1. Create a new container: `container create --name test-app ubuntu:latest`
2. Start the container: `container start test-app`
3. The container fails during bootstrap with the error:
   "failed to bootstrap container test-app"
4. The container exits with code 1
```

### Problem description

Describe what currently happens, what you expected to happen instead, and include any relevant log output.

#### Current behavior

- Exact error messages (copy-paste, don't paraphrase)
- Exit codes or status indicators
- Performance issues (slowness, hangs, crashes)
- Unexpected outputs or results

#### Expected behavior

- The output or result you anticipated
- A reference to documentation, if available
- How it behaved in previous versions, if applicable

#### Relevant logs

- Error messages or stack traces
- Warning messages related to your issue
- Output from failed commands

See [Log information](#log-information) below for how to collect logs for each project.

### Environment information

#### For all issues

Your macOS version:

```bash
sw_vers
```

```
ProductName:		macOS
ProductVersion:		26.0
BuildVersion:		25A354
```

Your Xcode version:

```bash
xcodebuild -version
```

```
Xcode 26.0
Build version 17A324
```

Also mention your Mac's chip (for example, M1 or M4 Pro).

#### For container issues

Your `container` version:

```bash
container --version
```

```
container CLI version 0.10.0-27-g9fd15f0 (build: debug, commit: 9fd15f0)
```

Also mention whether you installed from a release package or built from source.

#### For containerization issues

- **Containerization version**: The release tag or commit you're using. If you depend on the package, this is the `containerization` entry in your `Package.resolved`. If you're working from a checkout, run `git rev-parse HEAD`.
- **Swift version**: The output of `swift --version`.
- **Kernel**: Which guest kernel you're using — for example, the default kernel from `make fetch-default-kernel`, a kernel built with `make -C kernel`, or another kernel.
- **Platform**: Whether you're running on macOS (Virtualization.framework) or Linux (cloud-hypervisor). On Linux, include your distribution and the output of `uname -a`.

### Log information

#### Getting container logs

Run the failing command with debug output:

```bash
container --debug <command>
```

Get the logs from a container:

```bash
container logs <container-id>
```

For system-level issues, get the logs from the `container` system services:

```bash
container system logs
```

#### Getting containerization logs

- **Host logs**: The Containerization packages log through [swift-log](https://github.com/apple/swift-log). Set your logger to the `.debug` level and include the output around the failure. `cctl` logs at the debug level by default.
- **Guest boot logs**: Kernel and `vminitd` output is only available if you capture it. Set `bootLog` on your container's configuration (for example, `.file(path:)`) and include the resulting file.
- **Integration test failures**: Include the full output of `make integration` (or `make linux-integration` on Linux), not just the failing test's last line.

### Common information gaps

#### Missing context

- What were you trying to accomplish?
- What changed recently in your setup?
- Does the issue still occur on the `main` branch?

#### Incomplete error information

- Full error messages (not just the last line)
- Stack traces, where relevant
- Related warning messages

#### Environment variations

- Does it happen with a newly created container?
- Does it happen after a fresh install or a clean build?
- Have your network settings changed?
- Have your Xcode or macOS versions changed?

## New to open source?

### How do I pick something to work on?

Take a look at the `good first issue` label in the [containerization](https://github.com/apple/containerization/contribute) or [container](https://github.com/apple/container/contribute) project. 
Before you start working on an issue:
* Check the comments, assignees, and any references to pull requests — make sure nobody else is actively working on it, or awaiting help or review.
* If someone is assigned to the issue or volunteered to work on it, and there are no signs of progress or activity over at least the past month, don't hesitate to check in with them
* Leave a comment that you want to work on it, along with your plan. See [Working on an issue](#working-on-an-issue).

### Getting help

Don't be afraid to ask for help! When asking for help, provide as much information as possible, while highlighting anything you think may be important. Refer to the [MAINTAINERS.txt](MAINTAINERS.txt) file for the appropriate people to ping.

### I didn't get a response from someone. What should I do?

It's possible that you ask someone a question in an issue/pull request and you don't get a response as quickly as you'd like. If you don't get a response within a week, it's okay to politely ping them using an `@` mention. If you don't get a response for 2-3 weeks in a row, please ping someone else.

### I can't finish the contribution I started 

Sometimes an issue ends up bigger, harder, or more time-consuming than expected — **and that’s completely fine.** Be sure to comment on the issue saying you’re stepping away, so that someone else is able to pick it up.

## AI contribution guidelines

We welcome thoughtful use of AI tools in your contributions to Container and Containerization. We ask that you adhere to these rules in order to preserve the project's integrity, clarity, and quality, and to respect maintainer bandwidth:

* You should be able to explain and justify every line of code or documentation that was generated or assisted by AI. Your submission should reflect your own understanding and intent.
* Use AI to augment, not totally replace, your reasoning or familiarity, especially for non-trivial parts of the system. 
* Avoid dumping AI-generated walls of text that you cannot explain. Low-effort, unexplained submissions will be deprioritized to protect maintainer bandwidth.

AI tools should be used to **enhance, not replace** the human elements that make OSS special: learning, collaboration, and community growth.

## Code of conduct

To clarify what is expected of our contributors and community members, the Containerization team has adopted the code of conduct defined by the Contributor Covenant. This document is used across many open source communities and articulates our values well. For more detail, please read the [Code of Conduct](https://github.com/apple/.github/blob/main/CODE_OF_CONDUCT.md "Code of Conduct").
