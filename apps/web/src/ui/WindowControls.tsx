import { ICON, Icon } from './icons'

// The window controls (docs/design/chrome/spec.md, "The top-right controls"): one capsule at the
// conversation area's top right, Split, Commands, Inspector, as the Mac's WindowControls. The web
// has no split panes yet, so Split isn't drawn (the spec: a button that can't split would be a
// dead control); the rightmost button stays where the Mac's is.

function ChromeButton({ label, icon, tip, on, disabled, onClick }: { label: string; icon: string; tip: string; on?: boolean; disabled?: boolean; onClick: () => void }) {
  return (
    <button type="button" className="chrome-btn" aria-label={label} title={tip} aria-pressed={on === undefined ? undefined : on} disabled={disabled} onClick={onClick}>
      <Icon d={icon} size={17} stroke={1.8} />
    </button>
  )
}

export function WindowControls({ split, palette, paletteOpen, inspector, inspectorOpen, inspectorDisabled }: {
  /** Absent: this app has no split panes (the web, for now). */
  split?: () => void
  palette: () => void
  paletteOpen: boolean
  inspector: () => void
  inspectorOpen: boolean
  inspectorDisabled?: boolean
}) {
  return (
    <div className="window-controls" role="group" aria-label="Window controls">
      {split && <ChromeButton label="Split" icon={ICON.split} tip="Split pane (⌘\)" onClick={split} />}
      <ChromeButton label="Commands" icon={ICON.command} tip="Command palette (⌘K)" on={paletteOpen} onClick={palette} />
      <ChromeButton label="Inspector" icon={ICON.sidebarRight} tip="Inspector (⌥⌘0)" on={inspectorOpen} disabled={inspectorDisabled} onClick={inspector} />
    </div>
  )
}
