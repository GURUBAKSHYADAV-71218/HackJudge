export default function MagicLinkAuth() {
  return (
    <main style={{ minHeight:'100vh', display:'flex', flexDirection:'column', gap:16, alignItems:'center', justifyContent:'center', padding:24, background:'var(--bg)', color:'var(--ink)', textAlign:'center' }}>
      <h1 style={{ margin:0 }}>Judge invite links are paused</h1>
      <p style={{ maxWidth:480, color:'var(--muted)', lineHeight:1.6 }}>
        Ask the event organizer to assign the email address on your Google account. Then sign in with Google to open your judge dashboard.
      </p>
      <a href="#judge" style={{ color:'var(--blue)', fontWeight:600 }}>Open Judge Login</a>
    </main>
  );
}
