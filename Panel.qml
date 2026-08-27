import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "model/Shared.js" as Shared

Panel {
  id: root
  moduleName: "oameye.eduvpn"
  ipcTarget: "oameye.eduvpn"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string statusLine: vpn.actionStatus !== "" ? vpn.actionStatus : vpn.lastError

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  EduVpnBackend {
    id: vpn
    settings: root.settings
  }

  onOpenedChanged: if (opened) {
    vpn.refresh(true)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Connections {
    target: vpn
    function onTerminalRequired(command) {
      if (!root.bar) return
      root.bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(command))
      root.close()
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { vpn.refresh(true); return "ok" }
    function status(): string { return vpn.barSummary }
    function connect(): string { vpn.connect(); return "ok" }
    function disconnect(): string { vpn.disconnect(); return "ok" }
    function renew(): string { vpn.renew(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Shared.GLYPH_VPN
    dimmed: !vpn.connected
    tooltipText: "eduVPN: " + vpn.barSummary
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) vpn.toggleConnection()
      else if (buttonCode === Qt.MiddleButton) vpn.refresh(true)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(350))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(440))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: false
      onMoveRequested: function(dx, dy) {}
      onActivateRequested: vpn.toggleConnection()
      onCloseRequested: root.close()
      onTextKey: function(text) {
        if (text === "r" || text === "R") vpn.refresh(true)
        else if (text === "n" || text === "N") vpn.renew()
        else if (text === "d" || text === "D") vpn.disconnect()
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
          width: parent.width
          title: "eduVPN"
          meta: vpn.summary
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: vpn.connected ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              text: Shared.GLYPH_VPN
              color: vpn.connected ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        Text {
          visible: root.statusLine !== ""
          width: parent.width
          text: root.statusLine
          color: vpn.lastError !== "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Column {
          visible: vpn.connected && vpn.details.length > 0
          width: parent.width
          spacing: Style.spacing.labelGap

          Repeater {
            model: vpn.details
            delegate: RowLayout {
              width: parent.width
              spacing: Style.space(8)

              Text {
                text: modelData.label
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Item { Layout.fillWidth: true; implicitHeight: 1 }

              Text {
                text: modelData.value
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                Layout.maximumWidth: parent.width * 0.65
              }
            }
          }
        }

        Text {
          visible: !vpn.connected && vpn.configuredServers.length === 1
          width: parent.width
          text: vpn.configuredServers.length === 1
            ? "Configured server: " + vpn.configuredServers[0].label
            : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        PanelSeparator { foreground: root.foreground }

        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          ActionButton {
            label: vpn.connected ? "Disconnect" : "Connect"
            detail: vpn.connected ? "Stop the eduVPN tunnel" : "Start the configured server"
            actionable: vpn.detected && !vpn.actionBusy
            Layout.fillWidth: true
            onClicked: vpn.toggleConnection()
          }

          ActionButton {
            label: "Renew"
            detail: "Refresh authorization and reconnect"
            actionable: vpn.detected && vpn.connected && !vpn.actionBusy
            Layout.fillWidth: true
            onClicked: vpn.renew()
          }
        }

        Text {
          visible: vpn.setupHint !== ""
          width: parent.width
          text: vpn.setupHint
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          text: "Keys: Enter connect/disconnect, n renew, r refresh, d disconnect"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  component ActionButton: CursorSurface {
    id: action
    property string label: ""
    property string detail: ""
    property bool actionable: true

    implicitHeight: actionContent.implicitHeight + Style.spacing.rowPaddingX
    opacity: actionable ? 1.0 : 0.45
    foreground: root.foreground

    MouseArea {
      anchors.fill: parent
      enabled: action.actionable
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: action.clicked()
    }

    signal clicked()

    RowLayout {
      id: actionContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: action.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: action.detail
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
