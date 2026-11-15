import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Live stream to YouTube, X, Twitch or any RTMP(S) server without OBS.
// The heavy lifting is gpu-screen-recorder, driven by bin/livestream; this
// file only picks a destination and monitor and shows the live state.
Panel {
  id: root
  moduleName: "dhoenisch.livestream"
  ipcTarget: "dhoenisch.livestream"

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string helper: pluginDir + "/bin/livestream"
  readonly property string icon: String.fromCodePoint(0xF0003)

  readonly property int fps: Math.round(Number(setting("fps", 60))) || 60
  readonly property int bitrateKbps: Math.round(Number(setting("bitrateKbps", 6000))) || 6000

  // [{ id, name, ready }]
  property var destinations: []
  property var monitors: []
  property string selectedDestination: ""
  property string selectedMonitor: ""

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
    pollStatus()
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
      phase = "live"
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

  function start() {
    if (busy || live || !selectedDestination || !selectedMonitor) return
    if (!destinationReady(selectedDestination)) {
      error = strings.t("notConfigured").arg(destinationName(selectedDestination))
      return
    }
    error = ""
    phase = "starting"
    startProc.command = [helper, "start", selectedDestination, selectedMonitor, String(fps), String(bitrateKbps)]
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
    labelText: root.live && !vertical ? root.elapsed() : ""
    slotSize: Style.bar.iconSlot * (root.live && !vertical ? 2.6 : 1)
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.live ? root.stop() : root.start()
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

        PlainText {
          width: parent.width
          opacity: 0.6
          font.pixelSize: Style.font.caption
          text: strings.t("audio") + " · " + Commons.I18n.formatNumber(root.fps) + " fps · "
            + Commons.I18n.formatNumber(root.bitrateKbps) + " kbps"
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
