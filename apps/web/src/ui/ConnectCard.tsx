// The one card after an account's first finished turn, when it has no GitHub (connectCard.ts).
export function ConnectCard({ onConnect, onDismiss }: { onConnect: () => void; onDismiss: () => void }) {
  return (
    <section className="cardx outs" aria-label="Try it on your own code">
      <b style={{ fontSize: 15 }}>Try it on your own code</b>
      <div className="det wrap" style={{ marginTop: -4 }}>Connect GitHub and Frog can open pull requests on your repos.</div>
      <div style={{ display: 'flex', gap: 8 }}>
        <button type="button" className="f-btn f-btn--prominent" onClick={onConnect}>Connect GitHub</button>
        <button type="button" className="f-btn f-btn--bordered" onClick={onDismiss}>Keep going here</button>
      </div>
    </section>
  )
}
