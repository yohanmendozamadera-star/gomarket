import type { Metadata } from "next";
import "./globals.css";
import "./modules.css";
import "./categories.css";
import "./provider-access.css";
import "./product-catalog.css";
import "./storefront-catalog.css";


export const metadata: Metadata = {
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL || "http://localhost:3000"),
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
  return <html lang="es"><body>{children}</body></html>;
}
