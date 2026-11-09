import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Govee bar widget: a bulb in the bar and a panel listing every device on the
// Govee account with power, brightness, color, color temperature, modes, and
// scenes. All network traffic goes through govee.py, which keeps the API key
// in ~/.config/omarchy/govee/config.json (0600) and prints bounded JSON.
Panel {
  id: root
  moduleName: "govee"
  ipcTarget: "govee"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string script: decodeURIComponent(String(Qt.resolvedUrl("govee.py")).replace(/^file:\/\//, ""))

  // ---------------------------------------------------------------- state
  property var configured: null          // null until the first status check
  property var devices: []
  property bool loading: false
  property bool loadedOnce: false
  property string error: ""
  property bool editingKey: false
  property bool keyBusy: false
  property string keyMessage: ""
  property bool keyFailed: false
  property string expandedDevice: ""
  property var scenes: ({})              // device id -> [{name, value}] | "loading"
  property var busyDevices: ({})         // device id -> pending control count
  property int cursorIndex: 0
  property bool cursorActive: false
  property bool hexFieldFocused: false

  readonly property bool showKeyForm: configured === false || editingKey
  readonly property int onCount: Model.countOn(devices)
  readonly property bool anyOn: onCount > 0

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string bulbGlyph: anyOn ? String.fromCodePoint(0xF0335) : String.fromCodePoint(0xF0336)

  readonly property int refreshIntervalSec: Math.max(10, Number(setting("refreshIntervalSec", 30)) || 30)
  readonly property bool backgroundRefresh: setting("backgroundRefresh", false) === true
  readonly property int backgroundRefreshSec: Math.max(60, Number(setting("backgroundRefreshSec", 300)) || 300)

  readonly property string heroMeta: {
    if (configured === false) return strings.t("summary.noKey")
    if (loading && !loadedOnce) return strings.t("summary.loading")
    if (devices.length === 0) return strings.tn("summary.devices", 0).arg(0)
    return strings.t("summary.on").arg(Commons.I18n.formatNumber(onCount)).arg(Commons.I18n.formatNumber(devices.length))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------- helpers
  function run(proc, args) {
    proc.command = ["python3", "-I", root.script].concat(args)
    proc.running = true
  }

  function parse(text) {
    try {
      var obj = JSON.parse(String(text || "").trim().split("\n").pop() || "{}")
      return obj && typeof obj === "object" ? obj : { ok: false, error: strings.t("error.generic") }
    } catch (e) {
      return { ok: false, error: strings.t("error.generic") }
    }
  }

  function label(control) {
    return strings.t("control." + control.instance, control.label)
  }

  function checkStatus() {
    if (!statusProc.running) run(statusProc, ["status"])
  }

  function refresh() {
    if (configured === false || devicesProc.running) return
    loading = true
    run(devicesProc, ["devices"])
  }

  function saveKey(key) {
    key = String(key || "").trim()
    if (key === "" || keyProc.running) return
    keyBusy = true
    keyFailed = false
    keyMessage = strings.t("key.checking")
    run(keyProc, ["set-key"])
    keyProc.write(key + "\n")
  }

  function forgetKey() {
    if (!clearProc.running) run(clearProc, ["clear-key"])
  }

  function markBusy(deviceId, delta) {
    var next = {}
    for (var k in busyDevices) next[k] = busyDevices[k]
    next[deviceId] = Math.max(0, (next[deviceId] || 0) + delta)
    if (next[deviceId] === 0) delete next[deviceId]
    busyDevices = next
  }

  function sendControl(dev, type, instance, value) {
    if (!dev) return
    error = ""
    markBusy(dev.device, 1)
    // Optimistic: reflect the change now, roll forward on the next refresh.
    devices = Model.applyLocal(devices, dev.device, instance, value)
    var proc = controlProcComponent.createObject(root, { deviceId: dev.device })
    proc.command = ["python3", "-I", root.script, "control", dev.sku, dev.device, type, instance, JSON.stringify(value)]
    proc.running = true
  }

  function controlFinished(deviceId, text) {
    markBusy(deviceId, -1)
    var result = parse(text)
    if (!result.ok) {
      error = String(result.error || strings.t("error.generic"))
      if (result.needsKey) configured = false
      refreshSoon.restart()
    }
  }

  function setPower(dev, on) {
    if (!dev || !Model.hasPower(dev)) return
    sendControl(dev, "devices.capabilities.on_off", "powerSwitch", on ? 1 : 0)
  }

  function setAll(on) {
    for (var i = 0; i < devices.length; i++) {
      var d = devices[i]
      if (Model.hasPower(d) && Model.isOnline(d) && Model.isOn(d) !== on) setPower(d, on)
    }
  }

  function applyControl(dev, control, raw) {
    sendControl(dev, control.type, control.instance, Model.controlValue(control, raw))
  }

  function loadScenes(dev) {
    if (!dev || scenes[dev.device] !== undefined) return
    var next = {}
    for (var k in scenes) next[k] = scenes[k]
    next[dev.device] = "loading"
    scenes = next
    var proc = scenesProcComponent.createObject(root, { deviceId: dev.device })
    proc.command = ["python3", "-I", root.script, "scenes", dev.sku, dev.device]
    proc.running = true
  }

  function scenesFinished(deviceId, text) {
    var result = parse(text)
    var next = {}
    for (var k in scenes) next[k] = scenes[k]
    next[deviceId] = result.ok && Array.isArray(result.scenes) ? result.scenes : []
    scenes = next
  }

  function toggleExpanded(dev) {
    if (!dev) return
    expandedDevice = expandedDevice === dev.device ? "" : dev.device
    if (expandedDevice !== "" && Model.findCap(dev, "dynamic_scene", "lightScene")) loadScenes(dev)
  }

  function deviceAt(i) { return i >= 0 && i < devices.length ? devices[i] : null }

  function moveCursor(dy) {
    if (devices.length === 0) return
    cursorIndex = Math.max(0, Math.min(devices.length - 1, cursorIndex + dy))
    scrollCursorIntoView()
  }

  function scrollCursorIntoView() {
    var content = panel.loadedContent
    if (!content || !content.deviceColumn || !content.panelFlick) return
    var item = content.deviceColumn.children[cursorIndex]
    var flick = content.panelFlick
    if (!item) return
    Qt.callLater(function() {
      var margin = Style.space(6)
      var top = item.mapToItem(flick.contentItem, 0, 0).y
      var bottom = top + Math.min(item.height, flick.height)
      var maxY = Math.max(0, flick.contentHeight - flick.height)
      if (top < flick.contentY + margin) flick.contentY = Math.max(0, top - margin)
      else if (bottom > flick.contentY + flick.height - margin) flick.contentY = Math.min(maxY, bottom + margin - flick.height)
    })
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    checkStatus()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  Component.onCompleted: checkStatus()

  // ----------------------------------------------------------- processes
  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = root.parse(text)
        root.configured = result.ok ? result.configured === true : false
        if (root.configured && (root.opened || !root.loadedOnce)) root.refresh()
      }
    }
  }

  Process {
    id: devicesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = root.parse(text)
        root.loading = false
        if (result.ok && Array.isArray(result.devices)) {
          root.devices = result.devices
          root.loadedOnce = true
          root.error = ""
          if (root.cursorIndex >= root.devices.length) root.cursorIndex = Math.max(0, root.devices.length - 1)
        } else {
          root.error = String(result.error || strings.t("error.generic"))
          if (result.needsKey) root.configured = false
        }
      }
    }
  }

  Process {
    id: keyProc
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var result = root.parse(text)
        root.keyBusy = false
        if (result.ok) {
          root.keyFailed = false
          root.keyMessage = strings.tn("key.saved", result.deviceCount || 0).arg(result.deviceCount || 0)
          root.configured = true
          root.editingKey = false
          root.refresh()
        } else {
          root.keyFailed = true
          root.keyMessage = String(result.error || strings.t("error.generic"))
        }
      }
    }
  }

  Process {
    id: clearProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.devices = []
        root.loadedOnce = false
        root.expandedDevice = ""
        root.scenes = ({})
        root.keyMessage = ""
        root.editingKey = false
        root.checkStatus()
      }
    }
  }

  Component {
    id: controlProcComponent
    Process {
      id: controlProc
      property string deviceId: ""
      property bool streamDone: false
      property bool exited: false
      function maybeDestroy() { if (streamDone && exited) Qt.callLater(controlProc.destroy) }
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          root.controlFinished(controlProc.deviceId, text)
          controlProc.streamDone = true
          controlProc.maybeDestroy()
        }
      }
      onExited: { exited = true; maybeDestroy() }
    }
  }

  Component {
    id: scenesProcComponent
    Process {
      id: scenesProc
      property string deviceId: ""
      property bool streamDone: false
      property bool exited: false
      function maybeDestroy() { if (streamDone && exited) Qt.callLater(scenesProc.destroy) }
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          root.scenesFinished(scenesProc.deviceId, text)
          scenesProc.streamDone = true
          scenesProc.maybeDestroy()
        }
      }
      onExited: { exited = true; maybeDestroy() }
    }
  }

  // Govee's state endpoint lags a moment behind control calls; re-read
  // shortly after a failure so the optimistic UI snaps back to the truth.
  Timer { id: refreshSoon; interval: 1500; onTriggered: root.refresh() }

  Timer {
    interval: (root.opened ? root.refreshIntervalSec : root.backgroundRefreshSec) * 1000
    repeat: true
    running: root.configured === true && (root.opened || root.backgroundRefresh)
    onTriggered: if (Object.keys(root.busyDevices).length === 0) root.refresh()
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function allOn(): string { root.setAll(true); return "ok" }
    function allOff(): string { root.setAll(false); return "ok" }
    function status(): string { return root.heroMeta }
  }

  // ------------------------------------------------------------ bar icon
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.bulbGlyph
    foreground: root.anyOn ? root.barForeground : Qt.darker(root.barForeground, 1.55)
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.setAll(!root.anyOn)
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // --------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(620))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: panelFlick
      property alias deviceColumn: deviceColumn
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      blocked: keyField.activeFocus || root.hexFieldFocused
      onMoveRequested: function(dx, dy) {
        if (root.showKeyForm) return
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive && !root.showKeyForm) root.toggleExpanded(root.deviceAt(root.cursorIndex))
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.showKeyForm) return
        if (t === "r" || t === "R") root.refresh()
        else if (t === "p" || t === "P" || t === " ") {
          var d = root.deviceAt(root.cursorIndex)
          if (d) { root.cursorActive = true; root.setPower(d, !Model.isOn(d)) }
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: strings.t("title")
            meta: root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.anyOn ? 1.0 : 0.55
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.bulbGlyph
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(4)
                visible: root.configured === true && !root.editingKey

                PanelActionButton {
                  iconText: String.fromCodePoint(0xF0450)   // refresh
                  tooltipText: strings.t("refresh")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  anchors.verticalCenter: parent.verticalCenter
                  onClicked: root.refresh()
                }

                ToggleSwitch {
                  id: allSwitch
                  visible: root.devices.length > 0
                  checked: root.anyOn
                  foreground: root.foreground
                  anchors.verticalCenter: parent.verticalCenter
                  onToggled: root.setAll(!root.anyOn)
                  PanelToolTip {
                    visible: allSwitch.containsMouse
                    text: strings.t("allToggle")
                    fontFamily: root.fontFamily
                  }
                }
              }
            }
          }

          PlainText {
            visible: root.error !== "" && !root.showKeyForm
            width: parent.width
            text: root.error
            color: root.urgent
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ------------------------------------------------- API key form
          Column {
            visible: root.showKeyForm
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: strings.t("key.title")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            PlainText {
              width: parent.width
              text: strings.t("key.help")
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: keyField
                Layout.fillWidth: true
                password: true
                foreground: root.foreground
                placeholderText: strings.t("key.placeholder")
                enabled: !root.keyBusy
                onAccepted: root.saveKey(text)
              }

              Button {
                text: strings.t("key.save")
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !root.keyBusy && keyField.text.trim() !== ""
                onClicked: root.saveKey(keyField.text)
              }

              Button {
                visible: root.editingKey && root.configured === true
                text: strings.t("key.cancel")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: { root.editingKey = false; root.keyMessage = ""; keyField.text = "" }
              }
            }

            PlainText {
              visible: root.keyMessage !== ""
              width: parent.width
              text: root.keyMessage
              color: root.keyFailed ? root.urgent : root.dim
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            PlainText {
              width: parent.width
              text: strings.t("key.storedAt")
              color: root.dim
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Connections {
              target: root
              function onShowKeyFormChanged() {
                if (root.showKeyForm && root.opened) Qt.callLater(function() { keyField.forceActiveFocus() })
                if (!root.showKeyForm) keyField.text = ""
              }
              function onOpenedChanged() {
                if (root.opened && root.showKeyForm) Qt.callLater(function() { keyField.forceActiveFocus() })
              }
            }
          }

          // ---------------------------------------------------- devices
          Column {
            visible: !root.showKeyForm && root.configured === true
            width: parent.width
            spacing: Style.space(8)

            PlainText {
              visible: root.loadedOnce && root.devices.length === 0
              width: parent.width
              text: strings.t("devices.none")
              color: root.dim
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: deviceColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.devices
                DeviceCard {
                  required property var modelData
                  required property int index
                  width: deviceColumn.width
                  dev: modelData
                  rowIndex: index
                }
              }
            }

            PanelSeparator { foreground: root.foreground }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              PlainText {
                Layout.fillWidth: true
                text: strings.t("hint")
                color: root.dim
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              PanelActionButton {
                iconText: String.fromCodePoint(0xF0306)   // key
                tooltipText: strings.t("changeKey")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: { root.keyMessage = ""; root.editingKey = true }
              }

              PanelActionButton {
                iconText: String.fromCodePoint(0xF0343)   // logout
                tooltipText: strings.t("removeKey")
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.forgetKey()
              }
            }
          }
        }
      }
    }
  }

  // ----------------------------------------------------------- components
  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  component DeviceCard: Column {
    id: card
    property var dev: null
    property int rowIndex: 0
    readonly property bool expanded: dev && root.expandedDevice === dev.device
    readonly property bool online: Model.isOnline(dev)
    readonly property bool busy: dev && (root.busyDevices[dev.device] || 0) > 0
    readonly property var controls: expanded ? Model.controlsFor(dev) : []

    spacing: Style.space(4)

    CursorSurface {
      width: parent.width
      hasCursor: root.cursorActive && root.cursorIndex === card.rowIndex
      current: card.expanded
      foreground: root.foreground
      implicitHeight: rowLayout.implicitHeight + Style.spacing.rowPaddingX

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: { root.cursorActive = true; root.cursorIndex = card.rowIndex }
        onClicked: root.toggleExpanded(card.dev)
      }

      RowLayout {
        id: rowLayout
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(4)
        spacing: Style.space(10)

        Item {
          Layout.preferredWidth: Style.font.heading + Style.space(6)
          Layout.preferredHeight: Style.font.heading + Style.space(6)
          Layout.alignment: Qt.AlignVCenter

          // Color halo for lights that are on with a known RGB color.
          Rectangle {
            readonly property string hex: Model.intToHex(card.dev ? card.dev.state.colorRgb : undefined)
            anchors.fill: parent
            radius: width / 2
            visible: hex !== "" && Model.isOn(card.dev)
            color: hex !== "" ? hex : "transparent"
            opacity: 0.28
          }

          PlainText {
            anchors.centerIn: parent
            text: Model.typeGlyph(card.dev ? card.dev.type : "")
            color: card.online ? root.foreground : root.dim
            opacity: Model.isOn(card.dev) || !Model.hasPower(card.dev) ? 1.0 : 0.6
            font.pixelSize: Style.font.heading
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          PlainText {
            Layout.fillWidth: true
            text: card.dev ? card.dev.name : ""
            color: card.online ? root.foreground : root.dim
            elide: Text.ElideRight
          }

          PlainText {
            Layout.fillWidth: true
            text: card.dev ? Model.deviceMeta(card.dev, strings.t) : ""
            color: root.dim
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        ToggleSwitch {
          id: powerSwitch
          visible: Model.hasPower(card.dev)
          enabled: card.online
          opacity: card.online ? 1 : 0.4
          checked: Model.isOn(card.dev)
          busy: card.busy || !card.online
          foreground: root.foreground
          cursorRing: false
          Layout.alignment: Qt.AlignVCenter
          onHovered: function(on) { if (on) { root.cursorActive = true; root.cursorIndex = card.rowIndex } }
          onToggled: root.setPower(card.dev, !Model.isOn(card.dev))
        }
      }
    }

    // Expanded controls.
    Column {
      visible: card.expanded
      width: parent.width
      leftPadding: Style.space(12)
      rightPadding: Style.space(8)
      topPadding: Style.space(4)
      bottomPadding: Style.space(8)
      spacing: Style.space(10)

      PlainText {
        visible: card.controls.length === 0
        text: strings.t("device.noControls")
        color: root.dim
        font.pixelSize: Style.font.bodySmall
      }

      Repeater {
        model: card.controls
        Loader {
          required property var modelData
          width: parent.width - Style.space(20)
          property var control: modelData
          property var dev: card.dev
          sourceComponent: {
            switch (modelData.kind) {
            case "slider": return sliderControl
            case "toggle": return toggleControl
            case "color": return colorControl
            case "choice": return choiceControl
            case "scenes": return choiceControl
            case "readout": return readoutControl
            }
            return null
          }
        }
      }
    }
  }

  Component {
    id: sliderControl
    Column {
      readonly property var control: parent ? parent.control : null
      readonly property var dev: parent ? parent.dev : null
      width: parent ? parent.width : 0
      spacing: Style.space(2)

      RowLayout {
        width: parent.width
        PlainText {
          Layout.fillWidth: true
          text: control ? root.label(control) : ""
          font.pixelSize: Style.font.bodySmall
          color: root.dim
        }
        PlainText {
          text: control ? Commons.I18n.formatNumber(Math.round(slider.liveValue)) + control.unit : ""
          font.pixelSize: Style.font.bodySmall
        }
      }

      PanelSlider {
        id: slider
        width: parent.width
        bar: root.bar
        minimum: control ? control.min : 0
        maximum: control ? control.max : 100
        step: control ? Math.max(control.step, (control.max - control.min) / 50) : 1
        integer: control ? control.step >= 1 : true
        value: control ? control.value : 0
        // Warm-to-cool track for color temperature.
        fillColor: control && control.warmCool ? "#ffd29a" : (root.bar ? root.bar.foreground : Commons.Color.foreground)
        onReleased: function(v) { if (control) root.applyControl(dev, control, v) }
      }
    }
  }

  Component {
    id: toggleControl
    RowLayout {
      readonly property var control: parent ? parent.control : null
      readonly property var dev: parent ? parent.dev : null
      width: parent ? parent.width : 0

      PlainText {
        Layout.fillWidth: true
        text: control ? root.label(control) : ""
        font.pixelSize: Style.font.bodySmall
      }
      ToggleSwitch {
        checked: control ? control.value : false
        foreground: root.foreground
        cursorRing: false
        onToggled: if (control) root.applyControl(dev, control, !control.value)
      }
    }
  }

  Component {
    id: colorControl
    Column {
      readonly property var control: parent ? parent.control : null
      readonly property var dev: parent ? parent.dev : null
      readonly property string currentHex: control ? Model.intToHex(control.value) : ""
      width: parent ? parent.width : 0
      spacing: Style.space(6)

      PlainText {
        text: control ? root.label(control) : ""
        font.pixelSize: Style.font.bodySmall
        color: root.dim
      }

      Flow {
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: Model.SWATCHES
          Rectangle {
            required property string modelData
            readonly property bool selected: currentHex.toLowerCase() === modelData
            width: Style.space(22)
            height: width
            radius: Style.cornerRadius > 0 ? width / 2 : 0
            color: modelData
            border.width: selected || swatchMouse.containsMouse ? Math.max(2, Style.space(2)) : 1
            border.color: selected ? root.foreground : Qt.darker(root.foreground, swatchMouse.containsMouse ? 1.1 : 2.2)
            MouseArea {
              id: swatchMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (control) root.applyControl(dev, control, Model.hexToInt(parent.modelData))
            }
          }
        }

        TextField {
          id: hexField
          width: Style.space(96)
          verticalPadding: Style.space(3)
          foreground: root.foreground
          placeholderText: currentHex !== "" ? currentHex : strings.t("color.custom")
          maximumLength: 7
          validator: RegularExpressionValidator { regularExpression: /#?[0-9a-fA-F]{0,6}/ }
          onActiveFocusChanged: root.hexFieldFocused = activeFocus
          onAccepted: {
            var n = Model.hexToInt(text)
            if (n >= 0 && control) { root.applyControl(dev, control, n); text = "" }
          }
        }
      }
    }
  }

  Component {
    id: choiceControl
    Column {
      id: choiceRoot
      readonly property var control: parent ? parent.control : null
      readonly property var dev: parent ? parent.dev : null
      readonly property var sceneState: control && control.kind === "scenes" && dev ? root.scenes[dev.device] : undefined
      readonly property var options: {
        if (!control) return []
        if (control.kind !== "scenes") return control.options
        return Array.isArray(sceneState) ? sceneState.map(function(s) { return { label: s.name, value: s.value } }) : []
      }
      readonly property int currentIndex: {
        for (var i = 0; i < options.length; i++) if (control && Model.sameValue(options[i].value, control.value)) return i
        return -1
      }
      width: parent ? parent.width : 0
      spacing: Style.space(4)

      PlainText {
        text: control ? root.label(control) : ""
        font.pixelSize: Style.font.bodySmall
        color: root.dim
      }

      PlainText {
        visible: control && control.kind === "scenes" && !Array.isArray(sceneState) || (Array.isArray(sceneState) && sceneState.length === 0 && control.kind === "scenes")
        text: Array.isArray(sceneState) ? strings.t("scenes.none") : strings.t("scenes.loading")
        color: root.dim
        font.pixelSize: Style.font.caption
      }

      Dropdown {
        visible: choiceRoot.options.length > 0
        width: parent.width
        showLabel: false
        fontFamily: root.fontFamily
        value: choiceRoot.currentIndex >= 0 ? String(choiceRoot.currentIndex) : ""
        // Option labels come from the Govee cloud; Dropdown renders them in
        // its own Text, so strip anything markup-shaped first.
        options: choiceRoot.options.map(function(o, i) { return { value: String(i), label: String(o.label).replace(/[<>&]/g, "") } })
        onChanged: function(v) {
          var opt = choiceRoot.options[parseInt(v)]
          if (opt && choiceRoot.control) root.applyControl(choiceRoot.dev, choiceRoot.control, opt.value)
        }
      }
    }
  }

  Component {
    id: readoutControl
    RowLayout {
      readonly property var control: parent ? parent.control : null
      width: parent ? parent.width : 0
      PlainText {
        Layout.fillWidth: true
        text: control ? root.label(control) : ""
        font.pixelSize: Style.font.bodySmall
        color: root.dim
      }
      PlainText {
        text: control ? control.text : ""
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
