import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "hyprgrid.workspaces"

  function workspaceByName(name) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].name === name) return values[i]
    }

    return null
  }

  function workspaceNames() {
    var names = ["1", "2", "3", "4", "5"]
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var name = values[i].name
      if (/^\d+[a-z]*$/.test(name) && names.indexOf(name) === -1) names.push(name)
    }

    names.sort(compareWorkspaceNames)
    return names
  }

  function rebuildWorkspaceModel() {
    var names = root.workspaceNames()
    workspaceModel.clear()
    for (var i = 0; i < names.length; i++) workspaceModel.append({ workspaceName: names[i] })
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

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  Component.onCompleted: rebuildWorkspaceModel()

  Connections {
    target: Hyprland.workspaces
    function onValuesChanged() { root.rebuildWorkspaceModel() }
  }

  ListModel {
    id: workspaceModel
  }

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : workspaceModel.count
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: workspaceModel

      WidgetButton {
        required property string workspaceName

        readonly property var workspace: root.workspaceByName(workspaceName)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.name === workspaceName

        bar: root.bar
        text: workspaceName
        active: focused
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : -1
        fixedHeight: root.barSize
        onPressed: function() { root.focusWorkspace(workspaceName) }
      }
    }
  }
}
