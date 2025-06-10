# 🌈 📦️ Welcome to the Containerization community! 📦️ 🌈

Contributions to Containerization are welcomed and encouraged.

## How you can help

We would love your contributions in the form of:

🐛 Bug fixes\
⚡️ Performance improvements\
✨ API additions or enhancements\
📝 Documentation\
🧑‍💻 Project advocacy: blogs, conference talks, and more

Anything else that could enhance the project!

## Submitting Issues and Pull Requests

### Issues

To file a bug or feature request, use [GitHub issues](https://github.com/apple/containerization/issues/new).

🚧 For unexpected behavior or usability limitations, detailed instructions on how to reproduce the issue are appreciated. This will greatly help the priority setting and speed at which maintainers can get to your issue.

### Pull Requests

To make a pull request, use [GitHub](https://github.com/apple/containerization/compare). Please give the team a few days to review but it's ok to check in on occassion. We appreciate your contribution!

> [!IMPORTANT]
> If you plan to make substantial changes or add new features, we encourage you to first discuss them with the wider containerization developer community.
> You can do this by filing a [GitHub issue](https://github.com/apple/containerization/issues/new).
> This will save time and increases the chance of your pull request being accepted.

We use a "squash and merge" strategy to keep our `main` branch history clean and easy to follow. When your pull request
is merged, all of your commits will be combined into a single commit.

With the "squash and merge" strategy, the *title* and *body* of your pull request is extremely important. It will become the commit message
for the squashed commit. Think of it as the single, definitive description of your contribution.

Before merging, we'll review the pull request title and body to ensure it:

* Clearly and concisely describes the changes.
* Uses the imperative mood (e.g., "Add feature," "Fix bug").
* Provides enough context for future developers to understand the purpose of the change.

The pull request description should be concise and accurately describe the *what* and *why* of your changes.

#### Fomatting Contributions

Make sure your contributions are consistent with the rest of the project's formatting. You can do this using our Makefile:

```bash
make fmt
```

#### Applying License Header to New Files

If you submit a contribution that adds a new file, please add the license header. You can do this using our Makefile:

```bash
make update-licenses
```

## Code of Conduct

To clarify of what is expected of our contributors and community members, the Containerization team has adopted the code of conduct defined by the Contributor Covenant. This document is used across many open source communities and articulates our values well. For more detail, please read the [Code of Conduct](https://github.com/apple/.github/blob/main/CODE_OF_CONDUCT.md "Code of Conduct").
