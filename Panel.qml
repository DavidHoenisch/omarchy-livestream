import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Live stream to YouTube, X, Twitch or any RTMP(S) server without OBS.
// The heavy lifting is gpu-screen-recorder, driven by bin/livestream; this
// file picks the destination, monitor, webcam and audio, and drives the
// live controls (mic switch/mute, desktop audio, webcam) mid-stream.
Panel {
  id: root
  moduleName: "io.github.davidhoenisch.omarchystream"
  ipcTarget: "io.github.davidhoenisch.omarchystream"
  // Own the IPC target so it can carry the live controls below.
  manageIpc: false

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string helper: pluginDir + "/bin/livestream"
  readonly property string icon: String.fromCodePoint(0xF0003)
  readonly property string micIcon: String.fromCodePoint(0xF036C)
  readonly property string micOffIcon: String.fromCodePoint(0xF036D)
  readonly property string desktopIcon: String.fromCodePoint(0xF057E)

  readonly property int fps: Math.round(Number(setting("fps", 60))) || 60
  readonly property int bitrateKbps: Math.round(Number(setting("bitrateKbps", 6000))) || 6000
  readonly property string webcamSize: {
    var v = String(setting("webcamSize", "medium"))
    return ["small", "medium", "large"].indexOf(v) >= 0 ? v : "medium"
  }

  // [{ id, name, ready }]
  property var destinations: []
  property var monitors: []
  // [{ id: "none" | "/dev/videoN", name }]
  property var webcams: []
  property string selectedWebcam: ""
  property string selectedDestination: ""
  property string selectedMonitor: ""
  // [{ id: source name, name, isDefault }]
  property var mics: []
  property string selectedMic: ""
  property bool micMuted: false
  property bool desktopAudio: true
  property var controlQueue: []

  property string phase: "idle"   // idle | starting | live | stopping
  property string liveDestination: ""
  property string liveMonitor: ""
  property real liveSince: 0
  property real now: Date.now() / 1000
  property string error: ""

  readonly property color urgentColor: bar && bar.urgent !== undefined ? bar.urgent : Commons.Color.urgent
  readonly property bool live: phase === "live"
  readonly property bool busy: phase === "starting" || phase === "stopping"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function destinationName(id) {
    for (var i = 0; i < destinations.length; i++)
      if (destinations[i].id === id) return destinations[i].name
    return id
  }

  function destinationReady(id) {
    for (var i = 0; i < destinations.length; i++)
      if (destinations[i].id === id) return destinations[i].ready
    return false
  }

  function elapsed() {
    var s = Math.max(0, Math.floor(now - liveSince))
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60
    function pad(n) { return n < 10 ? "0" + n : String(n) }
    return (h > 0 ? h + ":" : "") + pad(m) + ":" + pad(sec)
  }

  function refresh() {
    if (!destProc.running) destProc.running = true
    if (!monitorProc.running) monitorProc.running = true
    if (!webcamProc.running) webcamProc.running = true
    if (!micProc.running) micProc.running = true
    pollStatus()
    if (live) syncAudio()
  }

  function syncAudio() {
    if (!audioProc.running) audioProc.running = true
  }

  function pollStatus() {
    if (!statusProc.running && !busy) statusProc.running = true
  }

  function parseStatus(raw) {
    var fields = String(raw || "").trim().split("\t")
    if (fields[0] === "live") {
      liveDestination = fields[1] || ""
      liveMonitor = fields[2] || ""
      liveSince = Number(fields[3]) || Date.now() / 1000
      var wasLive = phase === "live"
      phase = "live"
      if (!wasLive) syncAudio()
    } else {
      if (fields[0] === "ended" && phase === "live") {
        error = strings.t("ended") + (fields[1] ? ": " + fields[1] : "")
        notify(strings.t("notify.ended"), fields[1] || "")
      }
      phase = "idle"
    }
  }

  function parseDestinations(raw) {
    var list = []
    String(raw || "").split("\n").forEach(function(line) {
      var f = line.split("\t")
      if (f.length < 3 || !/^[a-z0-9_-]{1,32}$/.test(f[0])) return
      list.push({ id: f[0], name: f[1].slice(0, 40), ready: f[2] === "1" })
    })
    destinations = list
    if (!destinationReady(selectedDestination)) {
      var firstReady = list.filter(function(d) { return d.ready })[0]
      selectedDestination = firstReady ? firstReady.id : (list[0] ? list[0].id : "")
    }
  }

  function parseMonitors(raw) {
    var list = String(raw || "").split("\n").filter(function(n) { return /^[A-Za-z0-9_.-]{1,64}$/.test(n) })
    monitors = list
    if (list.indexOf(selectedMonitor) < 0) selectedMonitor = list[0] || ""
  }

  function parseWebcams(raw) {
    var list = [{ id: "none", name: strings.t("webcamOff") }]
    String(raw || "").split("\n").forEach(function(line) {
      var f = line.split("\t")
      if (f.length < 2 || !/^\/dev\/video[0-9]+$/.test(f[0])) return
      list.push({ id: f[0], name: f[1].slice(0, 40) })
    })
    webcams = list
    var ids = list.map(function(w) { return w.id })
    // Default to the first camera; keep the user's pick while it exists.
    if (ids.indexOf(selectedWebcam) < 0) selectedWebcam = list.length > 1 ? list[1].id : "none"
  }

  function parseMics(raw) {
    var list = []
    var fallback = ""
    String(raw || "").split("\n").forEach(function(line) {
      var f = line.split("\t")
      if (f.length < 3 || !/^[A-Za-z0-9_.:-]{1,200}$/.test(f[0])) return
      list.push({ id: f[0], name: f[1].slice(0, 40), isDefault: f[2] === "1" })
      if (f[2] === "1") fallback = f[0]
    })
    mics = list
    var ids = list.map(function(m) { return m.id })
    if (ids.indexOf(selectedMic) < 0) selectedMic = fallback || (list[0] ? list[0].id : "")
  }

  // What the running stream actually carries, so the panel never drifts.
  function parseAudio(raw) {
    String(raw || "").split("\n").forEach(function(line) {
      var f = line.split("\t")
      if (f[0] === "desktop") desktopAudio = f[1] === "on"
      else if (f[0] === "mic") {
        micMuted = f[1] === "off"
        if (!micMuted && /^[A-Za-z0-9_.:-]{1,200}$/.test(f[1] || "")) selectedMic = f[1]
      } else if (f[0] === "webcam") {
        selectedWebcam = /^\/dev\/video[0-9]+$/.test(f[1] || "") ? f[1] : "none"
      }
    })
  }

  // Live changes run one at a time through the helper.
  function control(args) {
    if (!live) return
    controlQueue = controlQueue.concat([args])
    runNextControl()
  }

  function runNextControl() {
    if (controlProc.running || controlQueue.length === 0) return
    controlProc.command = [helper].concat(controlQueue[0])
    controlQueue = controlQueue.slice(1)
    controlProc.running = true
  }

  function setDesktopAudio(on) {
    desktopAudio = on
    control(["desktop", on ? "on" : "off"])
  }

  function chooseMic(id) {
    selectedMic = id
    if (!micMuted) control(["mic", id])
  }

  function toggleMute() {
    if (!selectedMic) return
    micMuted = !micMuted
    control(["mic", micMuted ? "off" : selectedMic])
  }

  function chooseWebcam(id) {
    selectedWebcam = id
    control(id === "none" ? ["webcam", "off"] : ["webcam", id, webcamSize])
  }

  function start() {
    if (busy || live || !selectedDestination || !selectedMonitor) return
    if (!destinationReady(selectedDestination)) {
      error = strings.t("notConfigured").arg(destinationName(selectedDestination))
      return
    }
    error = ""
    phase = "starting"
    startProc.command = [helper, "start", selectedDestination, selectedMonitor, String(fps), String(bitrateKbps),
      selectedWebcam || "none", webcamSize,
      desktopAudio ? "on" : "off", micMuted || !selectedMic ? "off" : selectedMic]
    startProc.running = true
  }

  function stop() {
    if (busy || !live) return
    phase = "stopping"
    stopProc.running = true
  }

  function editKeys() {
    close()
    Util.execArgv(["bash", "-c", 'omarchy-launch-editor "$("$0" keys-path)"', helper])
  }

  function notify(summary, body) {
    Util.execArgv(["notify-send", "-a", "Live Stream", summary, body])
  }

  onOpenedChanged: if (opened) { error = ""; refresh() }
  Component.onCompleted: pollStatus()

  Process {
    id: destProc
    command: [root.helper, "destinations"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseDestinations(text) }
  }

  Process {
    id: monitorProc
    command: [root.helper, "monitors"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseMonitors(text) }
  }

  Process {
    id: webcamProc
    command: [root.helper, "webcams"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseWebcams(text) }
  }

  Process {
    id: micProc
    command: [root.helper, "mics"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseMics(text) }
  }

  Process {
    id: audioProc
    command: [root.helper, "audio"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseAudio(text) }
  }

  Process {
    id: controlProc
    property string errText: ""
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: controlProc.errText = String(text || "").trim().slice(0, 200) }
    onExited: function(exitCode) {
      if (exitCode !== 0 && controlProc.errText) root.error = controlProc.errText
      if (root.controlQueue.length > 0) root.runNextControl()
      else root.syncAudio()
    }
  }

  ShellIpc {
    target: "io.github.davidhoenisch.omarchystream"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function start(): void { root.start() }
    function stop(): void { root.stop() }
    function toggleLive(): void { root.live ? root.stop() : root.start() }
    function toggleMute(): void { root.toggleMute() }
    function toggleDesktopAudio(): void { root.setDesktopAudio(!root.desktopAudio) }
  }

  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseStatus(text) }
  }

  Process {
    id: startProc
    property string errText: ""
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: startProc.errText = String(text || "").trim().slice(0, 300) }
    onExited: function(exitCode) {
      root.phase = "idle"
      if (exitCode !== 0) {
        root.error = startProc.errText || "Failed to start"
      } else {
        root.notify(strings.t("notify.live").arg(root.destinationName(root.selectedDestination)), "")
      }
      root.pollStatus()
    }
  }

  Process {
    id: stopProc
    command: [root.helper, "stop"]
    onExited: { root.phase = "idle"; root.pollStatus() }
  }

  // Watch a running stream so an unexpected drop shows up in the bar.
  Timer { interval: 3000; running: root.live; repeat: true; onTriggered: root.pollStatus() }
  Timer { interval: 1000; running: root.live; repeat: true; onTriggered: root.now = Date.now() / 1000 }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    active: root.live
    labelText: root.live && !vertical ? root.elapsed() + (root.micMuted ? " " + root.micOffIcon : "") : ""
    slotSize: Style.bar.iconSlot * (root.live && !vertical ? (root.micMuted ? 3.4 : 2.6) : 1)
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.live ? root.stop() : root.start()
      else if (b === Qt.RightButton && root.live) root.toggleMute()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onActivateRequested: root.live ? root.stop() : root.start()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          PlainText {
            id: heroIcon
            text: root.icon
            color: root.live ? root.urgentColor : root.bar.foreground
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PlainText {
              text: strings.t("title")
              font.pixelSize: Style.font.title
              font.bold: true
              width: parent.width
            }

            PlainText {
              text: (root.phase === "starting" ? strings.t("status.starting")
                : root.phase === "stopping" ? strings.t("status.stopping")
                : root.live ? strings.t("status.live").arg(root.elapsed())
                : strings.t("status.idle")).toUpperCase()
              color: root.live ? root.urgentColor : Qt.darker(root.bar.foreground, 1.4)
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              width: parent.width
            }
          }
        }

        PlainText {
          visible: root.live
          width: parent.width
          wrapMode: Text.WordWrap
          opacity: 0.7
          font.pixelSize: Style.font.bodySmall
          text: strings.t("liveOn").arg(root.liveMonitor).arg(root.destinationName(root.liveDestination))
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Destination ----------
        Column {
          width: parent.width
          spacing: Style.space(10)
          enabled: !root.live && !root.busy
          opacity: enabled ? 1 : 0.5

          PanelSectionHeader {
            text: strings.t("destination")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          PlainText {
            visible: root.destinations.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            opacity: 0.6
            font.pixelSize: Style.font.bodySmall
            text: strings.t("noDestinations")
          }

          ChoiceRow {
            model: root.destinations
            labelOf: function(d) { return d.name }
            isActive: function(d) { return d.id === root.selectedDestination }
            isDim: function(d) { return !d.ready }
            onChosen: function(d) { root.selectedDestination = d.id; root.error = "" }
          }
        }

        // ---------- Monitor ----------
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.monitors.length > 1
          enabled: !root.live && !root.busy
          opacity: enabled ? 1 : 0.5

          PanelSectionHeader {
            text: strings.t("monitor")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          ChoiceRow {
            model: root.monitors
            labelOf: function(m) { return m }
            isActive: function(m) { return m === root.selectedMonitor }
            isDim: function(m) { return false }
            onChosen: function(m) { root.selectedMonitor = m }
          }
        }

        // ---------- Webcam ----------
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.webcams.length > 1
          enabled: !root.busy
          opacity: enabled ? 1 : 0.5

          PanelSectionHeader {
            text: strings.t("webcam")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          ChoiceRow {
            model: root.webcams
            labelOf: function(w) { return w.name }
            isActive: function(w) { return w.id === root.selectedWebcam }
            isDim: function(w) { return false }
            onChosen: function(w) { root.live ? root.chooseWebcam(w.id) : root.selectedWebcam = w.id }
          }
        }

        // ---------- Audio ----------
        Column {
          width: parent.width
          spacing: Style.space(10)
          enabled: !root.busy

          PanelSectionHeader {
            text: strings.t("audioSection")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: audioToggles
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing) / 2

            Button {
              width: audioToggles.cellWidth
              text: strings.t("desktopAudio")
              iconText: root.desktopIcon
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              active: root.desktopAudio
              opacity: root.desktopAudio ? 1 : 0.6
              onClicked: root.setDesktopAudio(!root.desktopAudio)
            }

            Button {
              width: audioToggles.cellWidth
              text: root.micMuted ? strings.t("micMuted") : strings.t("micLive")
              iconText: root.micMuted ? root.micOffIcon : root.micIcon
              fontSize: Style.font.bodySmall
              foreground: root.micMuted ? root.urgentColor : root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              active: !root.micMuted
              enabled: root.selectedMic !== ""
              onClicked: root.toggleMute()
            }
          }

          ChoiceRow {
            model: root.mics
            labelOf: function(m) { return m.name }
            isActive: function(m) { return m.id === root.selectedMic }
            isDim: function(m) { return root.micMuted }
            onChosen: function(m) { root.chooseMic(m.id) }
          }
        }

        PlainText {
          width: parent.width
          opacity: 0.6
          font.pixelSize: Style.font.caption
          text: Commons.I18n.formatNumber(root.fps) + " fps · " + Commons.I18n.formatNumber(root.bitrateKbps) + " kbps"
        }

        PlainText {
          visible: root.error !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          color: root.urgentColor
          font.pixelSize: Style.font.bodySmall
          text: root.error
        }

        // ---------- Actions ----------
        Row {
          id: actions
          width: parent.width
          spacing: Style.space(6)
          readonly property real cellWidth: (width - spacing) / 2

          Button {
            width: actions.cellWidth
            text: root.live ? strings.t("stop") : strings.t("goLive")
            iconText: root.icon
            fontSize: Style.font.bodySmall
            foreground: root.live ? root.urgentColor : root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            active: root.live
            enabled: !root.busy && (root.live || (root.selectedDestination !== "" && root.selectedMonitor !== ""))
            onClicked: root.live ? root.stop() : root.start()
          }

          Button {
            width: actions.cellWidth
            text: strings.t("editKeys")
            iconText: String.fromCodePoint(0xF0306)
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.editKeys()
          }
        }
      }
    }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.bar ? root.bar.foreground : Commons.Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    elide: Text.ElideRight
  }

  component ChoiceRow: Flow {
    id: flow
    property var model: []
    property var labelOf: function(x) { return String(x) }
    property var isActive: function(x) { return false }
    property var isDim: function(x) { return false }
    signal chosen(var item)

    width: parent.width
    spacing: Style.space(6)

    Repeater {
      model: flow.model
      Button {
        required property var modelData
        text: flow.labelOf(modelData)
        fontSize: Style.font.bodySmall
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        bordered: true
        active: flow.isActive(modelData)
        opacity: flow.isDim(modelData) ? 0.5 : 1
        onClicked: flow.chosen(modelData)
      }
    }
  }
}
