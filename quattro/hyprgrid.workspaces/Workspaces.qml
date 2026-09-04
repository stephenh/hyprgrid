import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "hyprgrid.workspaces"

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"
  readonly property string descriptionsPath: stateHome + "/hypr/workspace-descriptions.json"
  readonly property var monitor: root.QsWindow.window ? Hyprland.monitorFor(root.QsWindow.window.screen) : null
  readonly property bool monitorFocused: monitor !== null && Hyprland.focusedMonitor !== null && monitor.name === Hyprland.focusedMonitor.name
  readonly property var activeWorkspace: monitor && monitor.activeWorkspace ? monitor.activeWorkspace : Hyprland.focusedWorkspace
  readonly property string activeDescription: {
    if (!activeWorkspace) return ""
    var value = descriptions[descriptionKey(activeWorkspace.name)]
    return value === undefined || value === null ? "" : String(value)
  }
  property var descriptions: ({})

  function descriptionKey(name) {
    var match = String(name || "").match(/^\d+([a-z]+)$/)
    return match ? match[1] : String(name || "")
  }

  function loadDescriptions(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      descriptions = parsed && typeof parsed === "object" ? parsed : ({})
    } catch (error) {
      console.warn("hyprgrid.workspaces", "Ignoring invalid workspace descriptions", descriptionsPath, error)
      descriptions = ({})
    }
  }

  function workspaceByName(name) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].name === name) return values[i]
    }

    return null
  }

  function workspaceNames() {
    var names = []
    if (!root.monitor) return names

    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var workspace = values[i]
      if (!workspace.monitor || workspace.monitor.name !== root.monitor.name) continue

      var name = workspace.name
      if (/^\d+[a-z]*$/.test(name) && names.indexOf(name) === -1) names.push(name)
    }

    names.sort(compareWorkspaceNames)
    return names
  }

  function syncWorkspaceModel() {
    var names = root.workspaceNames()

    for (var targetIndex = 0; targetIndex < names.length; targetIndex++) {
      if (targetIndex >= workspaceModel.count) {
        workspaceModel.append({ workspaceName: names[targetIndex] })
        continue
      }

      if (workspaceModel.get(targetIndex).workspaceName === names[targetIndex]) continue

      var currentIndex = targetIndex + 1
      while (currentIndex < workspaceModel.count && workspaceModel.get(currentIndex).workspaceName !== names[targetIndex]) currentIndex++

      if (currentIndex < workspaceModel.count) {
        workspaceModel.move(currentIndex, targetIndex, 1)
      } else {
        workspaceModel.insert(targetIndex, { workspaceName: names[targetIndex] })
      }
    }

    while (workspaceModel.count > names.length) workspaceModel.remove(workspaceModel.count - 1)
  }

  function compareWorkspaceNames(left, right) {
    var leftParts = left.match(/^(\d+)([a-z]*)$/)
    var rightParts = right.match(/^(\d+)([a-z]*)$/)
    var columnDifference = Number(leftParts[1]) - Number(rightParts[1])
    if (columnDifference !== 0) return columnDifference
    if (leftParts[2] < rightParts[2]) return -1
    if (leftParts[2] > rightParts[2]) return 1
    return 0
  }

  function focusWorkspace(name) {
    if (!root.bar) return
    var workspace = root.workspaceByName(name)
    var selector = /^\d+$/.test(name) ? String(workspace ? workspace.id : Number(name)) : "name:" + name
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + selector + "\" })"))
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: content.implicitWidth + trailingGap
  implicitHeight: content.implicitHeight

  Component.onCompleted: syncWorkspaceModel()
  onMonitorChanged: syncWorkspaceModel()

  FileView {
    path: root.descriptionsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadDescriptions(text())
    onFileChanged: reload()
    onLoadFailed: root.descriptions = ({})
  }

  Connections {
    target: Hyprland.workspaces
    function onValuesChanged() { root.syncWorkspaceModel() }
  }

  Instantiator {
    model: Hyprland.workspaces
    delegate: Connections {
      required property var modelData
      target: modelData
      function onMonitorChanged() { root.syncWorkspaceModel() }
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event && event.name === "renameworkspace") root.syncWorkspaceModel()
    }
  }

  ListModel {
    id: workspaceModel
  }

  GridLayout {
    id: content
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : 2
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(1) : 0

    GridLayout {
      id: grid
      columns: root.vertical ? 1 : workspaceModel.count
      columnSpacing: root.vertical ? 0 : Style.space(1)
      rowSpacing: root.vertical ? Style.space(2) : 0

      Repeater {
        model: workspaceModel

        WidgetButton {
          id: workspaceButton
          required property string workspaceName

          readonly property var workspace: root.workspaceByName(workspaceName)
          readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
          readonly property bool focused: root.activeWorkspace !== null && root.activeWorkspace.name === workspaceName
          readonly property bool urgent: workspace !== null && workspace.urgent
          readonly property bool current: focused && root.monitorFocused

          bar: root.bar
          text: workspaceName
          labelVisible: false
          active: focused || urgent
          opacity: occupied || focused || urgent ? 1 : 0.5
          horizontalMargin: 6
          verticalPadding: 6
          fixedWidth: root.vertical ? root.barSize : -1
          fixedHeight: root.barSize
          onPressed: function() { root.focusWorkspace(workspaceName) }

          Text {
            anchors.centerIn: parent
            text: workspaceButton.text
            color: workspaceButton.active ? workspaceButton.activeColor : workspaceButton.foreground
            font.family: workspaceButton.fontFamily
            font.pixelSize: workspaceButton.fontSize
            renderType: Text.NativeRendering
          }

          Rectangle {
            id: workspaceIndicator
            visible: workspaceButton.urgent || workspaceButton.current
            color: workspaceButton.activeColor
            width: root.vertical ? 2 : parent.width
            height: root.vertical ? parent.height : 2
            x: root.vertical ? parent.width - width : 0
            y: root.vertical ? 0 : parent.height - height
            opacity: workspaceButton.current ? 1 : 0.2

            SequentialAnimation on opacity {
              running: workspaceButton.urgent && !workspaceButton.current
              loops: Animation.Infinite
              NumberAnimation { from: 0.2; to: 1; duration: 450; easing.type: Easing.InOutCubic }
              NumberAnimation { from: 1; to: 0.2; duration: 450; easing.type: Easing.InOutCubic }
            }
          }
        }
      }
    }

    WidgetButton {
      bar: root.bar
      text: root.activeDescription
      interactive: false
      pressable: false
      useActiveColor: false
      dimmed: true
      horizontalMargin: 10
      verticalPadding: 6
      fixedWidth: root.vertical ? root.barSize : -1
      fixedHeight: root.barSize
      textRotation: root.vertical ? -90 : 0
    }
  }
}
