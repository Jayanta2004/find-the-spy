import './globals.css'

export const metadata = {
  title: 'Find the Spy — A social deduction game',
  description: 'Gather your friends, ask sharp questions, and find the Spy.',
  applicationName: 'Find the Spy'
}

export default function RootLayout({ children }) {
  return <html lang="en"><body>{children}</body></html>
}
