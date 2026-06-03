//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ArgumentParser
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import vmnet

extension Sandboxy {
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run an AI coding agent in a sandboxed Linux container",
            discussion: """
                Available agents are determined by built-in definitions and any custom
                agent JSON files in the agents/ subdirectory of the sandboxy application
                support directory.
                """
        )

        @OptionGroup var options: AgentOptions

        @Argument(help: "Agent to run (e.g. claude)")
        var agent: String

        @Argument(parsing: .captureForPassthrough)
        var passthroughArgs: [String] = []

        func run() async throws {
            let config = try Sandboxy.loadConfig()

            let agents = AgentDefinition.allAgents(configRoot: Sandboxy.configRoot)
            guard let definition = agents[agent] else {
                let available = agents.keys.sorted().joined(separator: ", ")
                throw ValidationError(
                    "Unknown agent '\(agent)'. Available agents: \(available)"
                )
            }

            try await runAgent(
                config: config,
                agentName: agent,
                definition: definition,
                options: options,
                passthroughArgs: passthroughArgs
            )
        }
    }
}

struct AgentOptions: ParsableArguments {
    @Option(
        name: [.customLong("workspace"), .customShort("w")],
        help: "Workspace directory on the host (defaults to current directory)",
        completion: .directory,
        transform: { str in
            URL(fileURLWithPath: str, relativeTo: .currentDirectory())
                .absoluteURL.path(percentEncoded: false)
        })
    var workspace: String?

    @Option(name: .long, help: "Number of CPUs to allocate")
    var cpus: Int = 4

    @Option(name: .long, help: "Memory to allocate (e.g. 4g, 512m, 4096 for MB)")
    var memory: String = "4g"

    /// Parses the memory string into bytes. Supports suffixes: b, k/kb, m/mb, g/gb, t/tb.
    /// A bare number is treated as megabytes for backward compatibility.
    var memoryBytes: UInt64 {
        get throws {
            let str = memory.lowercased().trimmingCharacters(in: .whitespaces)
            guard !str.isEmpty else {
                throw ValidationError("Memory value cannot be empty")
            }

            let suffixes: [(String, UInt64)] = [
                ("tb", 1024 * 1024 * 1024 * 1024),
                ("gb", 1024 * 1024 * 1024),
                ("mb", 1024 * 1024),
                ("kb", 1024),
                ("t", 1024 * 1024 * 1024 * 1024),
                ("g", 1024 * 1024 * 1024),
                ("m", 1024 * 1024),
                ("k", 1024),
                ("b", 1),
            ]

            for (suffix, multiplier) in suffixes {
                if str.hasSuffix(suffix) {
                    let numStr = String(str.dropLast(suffix.count))
                    guard let value = Double(numStr), value > 0 else {
                        throw ValidationError("Invalid memory value: \(memory)")
                    }
                    return UInt64(value * Double(multiplier))
                }
            }

            // Bare number: treat as megabytes.
            guard let value = Double(str), value > 0 else {
                throw ValidationError("Invalid memory value: \(memory)")
            }
            return UInt64(value * 1024 * 1024)
        }
    }

    /// Returns a human-readable memory string (e.g. "4 GB", "512 MB").
    var memoryDisplay: String {
        get throws {
            let bytes = try memoryBytes
            if bytes >= 1024 * 1024 * 1024 && bytes % (1024 * 1024 * 1024) == 0 {
                return "\(bytes / (1024 * 1024 * 1024)) GB"
            } else if bytes >= 1024 * 1024 {
                return "\(bytes / (1024 * 1024)) MB"
            } else if bytes >= 1024 {
                return "\(bytes / 1024) KB"
            }
            return "\(bytes) B"
        }
    }

    @Option(
        name: .long, parsing: .upToNextOption,
        help: "Hostnames to allow through the HTTP proxy")
    var allowHosts: [String] = []

    @Flag(name: .long, help: "Disable network filtering (allow unrestricted network access)")
    var noNetworkFilter: Bool = false

    @Flag(name: .long, help: "Force reinstall of agent (ignore cached rootfs)")
    var reinstall: Bool = false

    @Flag(name: .long, help: "Forward the host SSH agent socket into the container")
    var sshAgent: Bool = false

    @Flag(name: .long, help: "Skip mounts defined in the agent configuration")
    var noAgentMounts: Bool = false

    @Flag(name: .customLong("rm"), help: "Automatically remove the instance after the session ends")
    var removeAfterRun: Bool = false

    @Option(
        name: [.customLong("mount"), .customShort("m")],
        parsing: .singleValue,
        help: "Additional mount in hostpath:containerpath[:ro|rw] format (repeatable)")
    var mount: [String] = []

    @Option(
        name: [.customLong("env"), .customShort("e")],
        parsing: .singleValue,
        help: "Set environment variable (KEY=VALUE or KEY to forward from host, repeatable)")
    var env: [String] = []

    @Option(
        name: .long,
        help: "Name for a persistent instance (preserves rootfs and resumes conversation)")
    var name: String?

    @Option(
        name: [.customLong("kernel"), .customShort("k")],
        help: "Path to Linux kernel binary (auto-downloads if omitted)",
        completion: .file(),
        transform: { str in
            URL(fileURLWithPath: str, relativeTo: .currentDirectory())
                .absoluteURL.path(percentEncoded: false)
        })
    var kernel: String?
}

func runAgent(
    config: SandboxyConfig,
    agentName: String,
    definition: AgentDefinition,
    options: AgentOptions,
    passthroughArgs: [String]
) async throws {
    signal(SIGINT) { _ in
        var termios = termios()
        tcgetattr(STDIN_FILENO, &termios)
        termios.c_lflag |= UInt(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSANOW, &termios)
        write(STDERR_FILENO, "\u{001B}[?25h", 6)
        _exit(130)
    }

    let hostWorkspacePath = options.workspace ?? FileManager.default.currentDirectoryPath
    let guestWorkspacePath = hostWorkspacePath
    let extraMounts = try options.mount.map { try MountSpec.parse($0) }
    let extraEnvVars = try options.env.map { try EnvSpec.resolve($0) }

    // Determine instance name: use --name if provided, otherwise auto-generate.
    let instanceName: String
    if let name = options.name {
        instanceName = name
    } else {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        instanceName = "\(agentName)-\(formatter.string(from: Date()))"
    }

    if let old = try InstanceState.find(name: instanceName, appRoot: Sandboxy.appRoot) {
        try? old.remove(appRoot: Sandboxy.appRoot)
    }

    // Check cache age for display.
    let cacheDir = Sandboxy.appRoot.appendingPathComponent("cache")
    let agentCachePath = cacheDir.appendingPathComponent("\(agentName)-rootfs.ext4")
    let cacheAgeLine: String
    if let attrs = try? FileManager.default.attributesOfItem(atPath: agentCachePath.path(percentEncoded: false)),
        let created = attrs[.creationDate] as? Date
    {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let age = formatter.localizedString(for: created, relativeTo: Date())
        let capitalizedAge = age.prefix(1).uppercased() + age.dropFirst()
        cacheAgeLine = "\u{1b}[1mEnvironment:\u{1b}[0m \(capitalizedAge)"
    } else {
        cacheAgeLine = "\u{1b}[1mEnvironment:\u{1b}[0m Not yet installed"
    }

    ProgressUI.printLogo(info: [
        "",
        "\u{1b}[1mSandboxy\u{1b}[0m",
        "\u{1b}[1mAgent:\u{1b}[0m \(definition.displayName)",
        "\u{1b}[1mInstance:\u{1b}[0m \(instanceName)",
        cacheAgeLine,
        "\u{1b}[1mWorkspace:\u{1b}[0m \(hostWorkspacePath)",
        "\u{1b}[1mCPUs:\u{1b}[0m \(options.cpus)  \u{1b}[1mMemory:\u{1b}[0m \(try options.memoryDisplay)",
    ])

    let kernelPath = try await KernelManager.ensureKernel(
        explicitPath: options.kernel,
        appRoot: Sandboxy.appRoot,
        config: config
    )
    guard FileManager.default.fileExists(atPath: kernelPath.path(percentEncoded: false)) else {
        throw SandboxyError.kernelNotFound(path: kernelPath.path(percentEncoded: false))
    }
    let kernel = Kernel(path: kernelPath, platform: .linuxArm)

    // Merge allowed hosts from agent definition and CLI flags.
    var allowedHosts = definition.allowedHosts
    allowedHosts.append(contentsOf: options.allowHosts)
    let filteringEnabled = !options.noNetworkFilter

    let filteredPassthroughArgs = passthroughArgs.filter { $0 != "--" }

    var fullCommand = definition.launchCommand
    fullCommand.append(contentsOf: filteredPassthroughArgs)
    ProgressUI.printDetail("\u{1b}[1mCommand:\u{1b}[0m \(fullCommand.joined(separator: " "))")

    if filteringEnabled {
        if allowedHosts.isEmpty {
            ProgressUI.printDetail("\u{1b}[1mAllowed hosts:\u{1b}[0m\u{1b}[33m none (all traffic denied)")
        } else {
            let hostList = allowedHosts.joined(separator: ", ")
            ProgressUI.printDetail("\u{1b}[1mAllowed hosts:\u{1b}[0m\u{1b}[32m \(hostList)")
        }
    } else {
        ProgressUI.printDetail("\u{1b}[1mAllowed hosts:\u{1b}[0m\u{1b}[32m unrestricted")
    }

    // Log mounts.
    ProgressUI.printDetail("\u{1b}[1mMounts:\u{1b}[0m")
    ProgressUI.printDetail("  \(hostWorkspacePath) -> \(guestWorkspacePath)")
    if options.noAgentMounts {
        for agentMount in definition.mounts {
            let ro = agentMount.readOnly ? " (ro)" : ""
            ProgressUI.printDetail("  \(agentMount.resolvedHostPath) -> \(agentMount.containerPath)\(ro) \u{1b}[33m(skipped, --no-agent-mounts)\u{1b}[0m")
        }
    } else {
        for agentMount in definition.mounts {
            let hostPath = agentMount.resolvedHostPath
            let ro = agentMount.readOnly ? " (ro)" : ""
            if FileManager.default.fileExists(atPath: hostPath) {
                ProgressUI.printDetail("  \(hostPath) -> \(agentMount.containerPath)\(ro)")
            } else {
                ProgressUI.printDetail("  \(hostPath) -> \(agentMount.containerPath)\(ro) \u{1b}[33m(skipped, host path not found)\u{1b}[0m")
            }
        }
    }
    for mountSpec in extraMounts {
        let ro = mountSpec.readOnly ? " (ro)" : ""
        ProgressUI.printDetail("  \(mountSpec.hostPath) -> \(mountSpec.containerPath)\(ro)")
    }

    // Setup networking.
    let enableNetworking: Bool
    var sharedNetwork: VmnetNetwork?
    if #available(macOS 26, *) {
        sharedNetwork = try VmnetNetwork()
        enableNetworking = true
    } else {
        sharedNetwork = nil
        enableNetworking = false
    }

    // Pull the init image with progress if it hasn't been cached yet.
    let initfsReference = config.initfsReference ?? SandboxyConfig.defaults.initfsReference!
    _ = try await pullImageWithProgress(reference: initfsReference)

    var manager = try await ContainerManager(
        kernel: kernel,
        initfsReference: initfsReference,
        root: Sandboxy.appRoot
    )

    /// MTU for vmnet interfaces. Lowered from the default 1500 to avoid
    /// PMTU black-hole issues on networks that block ICMP fragmentation-needed.
    let vmnetMTU: UInt32 = 1400

    let containerId = "\(agentName)-\(ProcessInfo.processInfo.processIdentifier)"

    //
    // Workload container setup
    //

    // Determine rootfs source: named instance > agent cache > fresh install.
    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    let containerRootfsPath = Sandboxy.appRoot
        .appendingPathComponent("containers")
        .appendingPathComponent(containerId)
        .appendingPathComponent("rootfs.ext4")

    let sourceRootfs: URL?
    var needsInstall = false

    if options.reinstall {
        removeIfExists(at: agentCachePath)
        removeIfExists(
            at: InstanceState.namedRootfsPath(appRoot: Sandboxy.appRoot, name: instanceName))
        sourceRootfs = nil
        needsInstall = true
    } else {
        let namedPath = InstanceState.namedRootfsPath(appRoot: Sandboxy.appRoot, name: instanceName)
        if FileManager.default.fileExists(atPath: namedPath.path(percentEncoded: false)) {
            sourceRootfs = namedPath
        } else if FileManager.default.fileExists(atPath: agentCachePath.path(percentEncoded: false)) {
            sourceRootfs = agentCachePath
        } else {
            sourceRootfs = nil
            needsInstall = true
        }
    }

    // Create workload container with full network for installation.
    // After install, we recreate with the filtered network if needed.
    var container: LinuxContainer

    if let sourceRootfs {
        let containerDir = Sandboxy.appRoot
            .appendingPathComponent("containers")
            .appendingPathComponent(containerId)
        try FileManager.default.createDirectory(at: containerDir, withIntermediateDirectories: true)

        let result = Darwin.clonefile(
            sourceRootfs.path(percentEncoded: false),
            containerRootfsPath.path(percentEncoded: false),
            0
        )
        if result != 0 {
            try FileManager.default.copyItem(at: sourceRootfs, to: containerRootfsPath)
        }

        let rootfsMount = Mount.block(
            format: "ext4",
            source: containerRootfsPath.path(percentEncoded: false),
            destination: "/",
            runtimeOptions: ["vzDiskImageSynchronizationMode=fsync"]
        )

        let image = try await pullImageWithProgress(reference: definition.baseImage)

        container = try await manager.create(
            containerId,
            image: image,
            rootfs: rootfsMount,
            networking: false
        ) { config in
            if enableNetworking, let iface = try sharedNetwork?.createInterface(containerId, mtu: vmnetMTU) {
                config.interfaces = [iface]
                config.dns = .init(nameservers: [sharedNetwork!.ipv4Gateway.description])
            }
            try configureContainer(
                config: &config,
                definition: definition,
                options: options,
                containerId: containerId,
                hostWorkspacePath: hostWorkspacePath,
                guestWorkspacePath: guestWorkspacePath,
                extraMounts: extraMounts
            )
        }
    } else {
        let progressConfig = try ProgressConfig(
            showTasks: true,
            showItems: true,
            ignoreSmallSize: true,
            totalTasks: 2
        )
        let progress = ProgressBar(config: progressConfig)
        defer { progress.finish() }
        progress.start()

        progress.set(description: "Pulling image (\(definition.baseImage))")
        progress.set(itemsName: "blobs")
        let image = try await Sandboxy.imageStore.pull(
            reference: definition.baseImage,
            progress: progressEventAdapter(for: progress)
        )

        progress.set(description: "Unpacking image")
        container = try await manager.create(
            containerId,
            image: image,
            rootfsSizeInBytes: 512.gib(),
            networking: false
        ) { config in
            if enableNetworking, let iface = try sharedNetwork?.createInterface(containerId, mtu: vmnetMTU) {
                config.interfaces = [iface]
                config.dns = .init(nameservers: [sharedNetwork!.ipv4Gateway.description])
            }
            try configureContainer(
                config: &config,
                definition: definition,
                options: options,
                containerId: containerId,
                hostWorkspacePath: hostWorkspacePath,
                guestWorkspacePath: guestWorkspacePath,
                extraMounts: extraMounts
            )
        }
    }

    // Boot and install toolchain if needed (with full network).
    if needsInstall {
        try await container.create()
        try await container.start()

        ProgressUI.printStatus("Installing \(definition.displayName) toolchain...")
        try await installAgent(in: container, definition: definition)
        ProgressUI.printStatus("Installation complete.")

        try await container.stop()
        ProgressUI.printDetail("Caching environment for future runs...")
        try FileManager.default.copyItem(at: containerRootfsPath, to: agentCachePath)

        // Delete so we can recreate (possibly on a different network).
        try manager.delete(containerId)
        try? sharedNetwork?.releaseInterface(containerId)

        // Recreate from the freshly-cached rootfs (unless filtering will recreate again).
        if !filteringEnabled {
            let cachedRootfsMount = Mount.block(
                format: "ext4",
                source: containerRootfsPath.path(percentEncoded: false),
                destination: "/",
                runtimeOptions: ["vzDiskImageSynchronizationMode=fsync"]
            )
            let cachedImage = try await pullImageWithProgress(reference: definition.baseImage)
            container = try await manager.create(
                containerId,
                image: cachedImage,
                rootfs: cachedRootfsMount,
                networking: false
            ) { config in
                if enableNetworking, let iface = try sharedNetwork?.createInterface(containerId, mtu: vmnetMTU) {
                    config.interfaces = [iface]
                    config.dns = .init(nameservers: [sharedNetwork!.ipv4Gateway.description])
                }
                try configureContainer(
                    config: &config,
                    definition: definition,
                    options: options,
                    containerId: containerId,
                    hostWorkspacePath: hostWorkspacePath,
                    guestWorkspacePath: guestWorkspacePath,
                    extraMounts: extraMounts
                )
            }
        }
    }

    // Host-only network setup (only when filtering is active)
    var proxyIP: String?
    var hostOnlyNetwork: VmnetNetwork?

    if filteringEnabled, enableNetworking, #available(macOS 26, *) {
        hostOnlyNetwork = try VmnetNetwork(mode: .VMNET_HOST_MODE)

        let gatewayIP = hostOnlyNetwork!.ipv4Gateway.description
        let workloadHostOnlyInterface = try hostOnlyNetwork!.createInterface(containerId, mtu: vmnetMTU)
        proxyIP = gatewayIP

        // Recreate the workload container on the host-only network.
        if !needsInstall {
            try manager.delete(containerId)
            try? sharedNetwork?.releaseInterface(containerId)
        }

        let filteredContainerDir = Sandboxy.appRoot
            .appendingPathComponent("containers")
            .appendingPathComponent(containerId)
        try FileManager.default.createDirectory(at: filteredContainerDir, withIntermediateDirectories: true)

        let filteredRootfsSource = needsInstall ? agentCachePath : (sourceRootfs ?? agentCachePath)
        let cloneResult2 = Darwin.clonefile(
            filteredRootfsSource.path(percentEncoded: false),
            containerRootfsPath.path(percentEncoded: false),
            0
        )
        if cloneResult2 != 0 {
            try FileManager.default.copyItem(at: filteredRootfsSource, to: containerRootfsPath)
        }

        let filteredRootfsMount = Mount.block(
            format: "ext4",
            source: containerRootfsPath.path(percentEncoded: false),
            destination: "/",
            runtimeOptions: ["vzDiskImageSynchronizationMode=fsync"]
        )

        let image = try await pullImageWithProgress(reference: definition.baseImage)

        container = try await manager.create(
            containerId,
            image: image,
            rootfs: filteredRootfsMount,
            networking: false
        ) { config in
            if let iface = workloadHostOnlyInterface {
                config.interfaces = [iface]
                config.dns = .init(nameservers: [gatewayIP])
            }
            try configureContainer(
                config: &config,
                definition: definition,
                options: options,
                containerId: containerId,
                hostWorkspacePath: hostWorkspacePath,
                guestWorkspacePath: guestWorkspacePath,
                extraMounts: extraMounts
            )
        }
    }

    // Run the container session, cleaning up on both success and failure.
    do {
        try await runContainerSession(
            container: container,
            containerId: containerId,
            instanceName: instanceName,
            agentName: agentName,
            definition: definition,
            options: options,
            containerRootfsPath: containerRootfsPath,
            agentCachePath: agentCachePath,
            hostWorkspacePath: hostWorkspacePath,
            guestWorkspacePath: guestWorkspacePath,
            extraEnvVars: extraEnvVars,
            proxyIP: proxyIP,
            allowedHosts: allowedHosts,
            passthroughArgs: filteredPassthroughArgs
        )

        // Cleanup
        try manager.delete(containerId)
        try? sharedNetwork?.releaseInterface(containerId)
        if hostOnlyNetwork != nil {
            try? hostOnlyNetwork?.releaseInterface(containerId)
        }
    } catch {
        do {
            try await container.stop()
        } catch {
            log.warning("Failed to stop container \(containerId): \(error)")
        }
        do {
            try manager.delete(containerId)
        } catch {
            log.warning("Failed to delete container \(containerId): \(error)")
        }
        try? sharedNetwork?.releaseInterface(containerId)
        if hostOnlyNetwork != nil {
            try? hostOnlyNetwork?.releaseInterface(containerId)
        }
        throw error
    }
}

private func runContainerSession(
    container: LinuxContainer,
    containerId: String,
    instanceName: String,
    agentName: String,
    definition: AgentDefinition,
    options: AgentOptions,
    containerRootfsPath: URL,
    agentCachePath: URL,
    hostWorkspacePath: String,
    guestWorkspacePath: String,
    extraEnvVars: [String],
    proxyIP: String?,
    allowedHosts: [String],
    passthroughArgs: [String]
) async throws {
    // create() boots the VM and brings up the vmnet bridge on the host.
    try await container.create()

    // Start the proxy now that the bridge interface is up.
    var hostProxy: HostProxy?
    if let proxyIP {
        let proxy = try await HostProxy(
            host: proxyIP,
            port: 0,
            allowedHosts: allowedHosts
        )
        hostProxy = proxy
    }

    // start() launches the container process.
    try await container.start()

    // Write instance state.
    let instanceState = InstanceState(
        id: containerId,
        name: instanceName,
        agent: agentName,
        workspace: hostWorkspacePath,
        status: .running,
        createdAt: Date(),
        cpus: options.cpus,
        memoryMB: try options.memoryBytes / (1024 * 1024)
    )
    try instanceState.save(appRoot: Sandboxy.appRoot)

    let sigwinchStream = AsyncSignalHandler.create(notify: [SIGWINCH])
    let current = try Terminal.current
    try current.setraw()
    defer { current.tryReset() }

    // Build environment for the agent process.
    var envVarsBuilder = [
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "TERM=xterm-256color",
        "HOME=/root",
    ]
    for envVar in definition.environmentVariables {
        if envVar.contains("=") {
            envVarsBuilder.append(envVar)
        } else if let value = ProcessInfo.processInfo.environment[envVar] {
            envVarsBuilder.append("\(envVar)=\(value)")
        }
    }

    envVarsBuilder.append(contentsOf: extraEnvVars)

    if options.sshAgent, ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] != nil {
        envVarsBuilder.append("SSH_AUTH_SOCK=/tmp/ssh-agent.sock")
    }

    if let proxyIP, let proxyPort = hostProxy?.port {
        let proxyURL = "http://\(proxyIP):\(proxyPort)"
        envVarsBuilder.append("HTTP_PROXY=\(proxyURL)")
        envVarsBuilder.append("HTTPS_PROXY=\(proxyURL)")
        envVarsBuilder.append("http_proxy=\(proxyURL)")
        envVarsBuilder.append("https_proxy=\(proxyURL)")
        envVarsBuilder.append("NO_PROXY=localhost,127.0.0.1")
        envVarsBuilder.append("no_proxy=localhost,127.0.0.1")
        envVarsBuilder.append("GLOBAL_AGENT_HTTP_PROXY=\(proxyURL)")
        envVarsBuilder.append("GLOBAL_AGENT_HTTPS_PROXY=\(proxyURL)")
        envVarsBuilder.append("GLOBAL_AGENT_NO_PROXY=localhost,127.0.0.1")

        // Prepend global-agent bootstrap to NODE_OPTIONS so Node.js http/https
        // modules respect the proxy environment variables.
        if let idx = envVarsBuilder.firstIndex(where: { $0.hasPrefix("NODE_OPTIONS=") }) {
            let existing = String(envVarsBuilder[idx].dropFirst("NODE_OPTIONS=".count))
            envVarsBuilder[idx] = "NODE_OPTIONS=-r /usr/local/lib/node_modules/global-agent/dist/routines/bootstrap.js \(existing)"
        } else {
            envVarsBuilder.append("NODE_OPTIONS=-r /usr/local/lib/node_modules/global-agent/dist/routines/bootstrap.js")
        }
    }

    var launchArgsBuilder = definition.launchCommand
    launchArgsBuilder.append(contentsOf: passthroughArgs)

    let envVars = envVarsBuilder
    let launchArgs = launchArgsBuilder

    let agentProcess = try await container.exec("agent-session") { config in
        config.arguments = launchArgs
        config.environmentVariables = envVars
        config.workingDirectory = guestWorkspacePath
        config.terminal = true
        config.stdin = current
        config.stdout = current
    }

    try await agentProcess.start()
    try? await agentProcess.resize(to: try current.size)

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for await _ in sigwinchStream.signals {
                try await agentProcess.resize(to: try current.size)
            }
        }

        let status = try await agentProcess.wait()
        group.cancelAll()

        try await agentProcess.delete()

        // Stop container so rootfs is cleanly unmounted before caching.
        try await container.stop()

        if options.removeAfterRun {
            ProgressUI.printStatus("Instance \u{1b}[1m\(instanceName)\u{1b}[0m removed (--rm).")
        } else {
            // Preserve the rootfs for all instances.
            let namedDir = InstanceState.namedRootfsDir(appRoot: Sandboxy.appRoot)
            try FileManager.default.createDirectory(at: namedDir, withIntermediateDirectories: true)
            let namedPath = InstanceState.namedRootfsPath(appRoot: Sandboxy.appRoot, name: instanceName)
            removeIfExists(at: namedPath)
            try FileManager.default.copyItem(at: containerRootfsPath, to: namedPath)

            let stopped = InstanceState(
                id: instanceState.id,
                name: instanceState.name,
                agent: instanceState.agent,
                workspace: instanceState.workspace,
                status: .stopped,
                createdAt: instanceState.createdAt,
                stoppedAt: Date(),
                cpus: instanceState.cpus,
                memoryMB: instanceState.memoryMB
            )
            try stopped.save(appRoot: Sandboxy.appRoot)

            ProgressUI.printStatus("Instance \u{1b}[1m\(instanceName)\u{1b}[0m saved. Resume with: sandboxy run \(agentName) --name \(instanceName)")
        }

        if status.exitCode != 0 {
            throw ExitCode(status.exitCode)
        }
    }

    if let proxy = hostProxy {
        try await proxy.stop()
    }
}

private func configureContainer(
    config: inout LinuxContainer.Configuration,
    definition: AgentDefinition,
    options: AgentOptions,
    containerId: String,
    hostWorkspacePath: String,
    guestWorkspacePath: String,
    extraMounts: [MountSpec]
) throws {
    config.cpus = options.cpus
    config.memoryInBytes = try options.memoryBytes

    config.process.arguments = ["/bin/sleep", "infinity"]
    config.process.workingDirectory = "/"
    config.process.capabilities = .allCapabilities
    config.useInit = true

    // SSH agent forwarding.
    if options.sshAgent,
        let authSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
    {
        let guestSocketPath = "/tmp/ssh-agent.sock"
        config.sockets.append(
            UnixSocketConfiguration(
                source: URL(fileURLWithPath: authSock),
                destination: URL(fileURLWithPath: guestSocketPath),
                direction: .into
            )
        )
    }

    config.mounts.append(
        Mount.share(
            source: hostWorkspacePath,
            destination: guestWorkspacePath
        )
    )

    if !options.noAgentMounts {
        for agentMount in definition.mounts {
            let hostPath = agentMount.resolvedHostPath
            if FileManager.default.fileExists(atPath: hostPath) {
                config.mounts.append(
                    Mount.share(
                        source: hostPath,
                        destination: agentMount.containerPath,
                        options: agentMount.readOnly ? ["ro"] : []
                    )
                )
            }
        }
    }

    for mountSpec in extraMounts {
        config.mounts.append(mountSpec.toMount())
    }

    var hosts = Hosts.default
    if #available(macOS 26, *), !config.interfaces.isEmpty {
        let interface = config.interfaces[0]
        hosts.entries.append(
            Hosts.Entry(
                ipAddress: interface.ipv4Address.address.description,
                hostnames: [containerId]
            )
        )
    }
    config.hosts = hosts
}

func installAgent(
    in container: LinuxContainer,
    definition: AgentDefinition
) async throws {
    for (index, command) in definition.installCommands.enumerated() {
        let truncated = command.count > 80 ? String(command.prefix(77)) + "..." : command
        ProgressUI.printDetail("[\(index + 1)/\(definition.installCommands.count)] \(truncated)")

        let buffer = OutputCapture(streamToStdout: true)
        let execId = "install-\(index)"
        let process = try await container.exec(execId) { config in
            config.arguments = ["/bin/sh", "-c", command]
            config.workingDirectory = "/"
            config.stdout = buffer
            config.stderr = buffer
            config.capabilities = .allCapabilities
            config.environmentVariables = [
                "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "DEBIAN_FRONTEND=noninteractive",
                "HOME=/root",
            ]
        }

        try await process.start()
        let status = try await process.wait()
        try await process.delete()

        guard status.exitCode == 0 else {
            throw SandboxyError.installFailed(
                step: index + 1,
                command: command,
                exitCode: status.exitCode
            )
        }
    }
}

func removeIfExists(at url: URL) {
    let path = url.path(percentEncoded: false)
    if FileManager.default.fileExists(atPath: path) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            log.warning("Failed to remove \(path): \(error)")
        }
    }
}

/// A parsed `hostpath:containerpath[:ro|rw]` mount specification from the CLI.
struct MountSpec {
    let hostPath: String
    let containerPath: String
    let readOnly: Bool

    static func parse(_ spec: String) throws -> MountSpec {
        let parts = spec.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            throw SandboxyError.invalidMountSpec(spec: spec)
        }

        let readOnly: Bool
        if parts.count == 3 {
            switch parts[2] {
            case "ro":
                readOnly = true
            case "rw":
                readOnly = false
            default:
                throw SandboxyError.invalidMountSpec(spec: spec)
            }
        } else {
            readOnly = false
        }

        // Resolve host path to absolute.
        let hostPath = URL(fileURLWithPath: parts[0], relativeTo: .currentDirectory())
            .absoluteURL.path(percentEncoded: false)

        return MountSpec(hostPath: hostPath, containerPath: parts[1], readOnly: readOnly)
    }

    func toMount() -> Containerization.Mount {
        Containerization.Mount.share(
            source: hostPath,
            destination: containerPath,
            options: readOnly ? ["ro"] : []
        )
    }
}

func progressEventAdapter(for progress: ProgressBar) -> ProgressHandler {
    { events in
        for event in events {
            switch event.event {
            case "add-size":
                if let value = event.value as? Int64 {
                    progress.add(size: value)
                }
            case "add-total-size":
                if let value = event.value as? Int64 {
                    progress.add(totalSize: value)
                }
            case "add-items":
                if let value = event.value as? Int {
                    progress.add(items: value)
                }
            case "add-total-items":
                if let value = event.value as? Int {
                    progress.add(totalItems: value)
                }
            default:
                break
            }
        }
    }
}

/// Pulls an image, showing a progress bar only if the image isn't already cached locally.
func pullImageWithProgress(reference: String) async throws -> Containerization.Image {
    do {
        return try await Sandboxy.imageStore.get(reference: reference)
    } catch {
        let progressConfig = try ProgressConfig(
            description: "Pulling image (\(reference))",
            showItems: true,
            ignoreSmallSize: true
        )
        let progress = ProgressBar(config: progressConfig)
        defer { progress.finish() }
        progress.start()
        progress.set(itemsName: "blobs")
        return try await Sandboxy.imageStore.pull(
            reference: reference,
            progress: progressEventAdapter(for: progress)
        )
    }
}

/// Resolves a `KEY=VALUE` or `KEY` environment variable specification.
///
/// - `KEY=VALUE`: passed through as-is.
/// - `KEY`: looks up the variable in the host environment and produces `KEY=<value>`.
///   Throws if the variable is not set.
enum EnvSpec {
    static func resolve(_ spec: String) throws -> String {
        if let eqIndex = spec.firstIndex(of: "=") {
            // KEY=VALUE: Use as-is, but validate key is non-empty.
            let key = spec[spec.startIndex..<eqIndex]
            guard !key.isEmpty else {
                throw SandboxyError.envVarNotSet(name: "")
            }
            return spec
        }

        // KEY: Forward from host.
        guard let value = ProcessInfo.processInfo.environment[spec] else {
            throw SandboxyError.envVarNotSet(name: spec)
        }
        return "\(spec)=\(value)"
    }
}
