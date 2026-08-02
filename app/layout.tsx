import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geist = Geist({ variable: "--font-geist", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-mono", subsets: ["latin"] });

export const metadata: Metadata = {
  title: "GoMarket · Todo lo bueno, más cerca de ti",
  description: "El marketplace local que conecta compradores con los mejores comercios de su ciudad.",
  icons: { icon: "/favicon.svg" },
  openGraph: {
    title: "GoMarket · Todo lo bueno, más cerca de ti",
    description: "Compra local en un solo lugar.",
    images: [{ url: "/og.png", width: 1200, height: 630, alt: "GoMarket, marketplace local" }],
  },
  twitter: { card: "summary_large_image", images: ["/og.png"] },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="es"><body className={`${geist.variable} ${geistMono.variable}`}>{children}</body></html>;
}
