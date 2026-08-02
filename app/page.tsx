"use client";

import { useMemo, useState } from "react";

const products = [
  { id: 1, name: "Aguacate Hass premium", store: "Huerta del Valle", price: 8900, old: 10900, rating: "4.9", tag: "-18%", image: "🥑", color: "#dfeec9", unit: "Malla x 4" },
  { id: 2, name: "Salmón fresco porción", store: "Mar & Río", price: 24900, old: 28900, rating: "4.8", tag: "-14%", image: "🐟", color: "#fee0da", unit: "500 g" },
  { id: 3, name: "Pan artesanal de masa madre", store: "Miga Casa", price: 12500, old: null, rating: "4.9", tag: "Nuevo", image: "🥖", color: "#f6e8c8", unit: "650 g" },
  { id: 4, name: "Fresas seleccionadas", store: "Frutos de Casa", price: 9900, old: 12900, rating: "4.7", tag: "-23%", image: "🍓", color: "#ffe0e6", unit: "Bandeja 500 g" },
  { id: 5, name: "Café especial de origen", store: "Cumbre Café", price: 27800, old: null, rating: "5.0", tag: "Top", image: "☕", color: "#ede1d4", unit: "340 g" },
  { id: 6, name: "Queso campesino fresco", store: "La Vaquita", price: 16800, old: 18500, rating: "4.8", tag: "-9%", image: "🧀", color: "#fff3c7", unit: "500 g" },
];

const categories = [
  ["🥬", "Frutas y verduras", "1.240 productos"],
  ["🥩", "Carnes y pescados", "684 productos"],
  ["🥛", "Lácteos y huevos", "920 productos"],
  ["🥐", "Panadería", "356 productos"],
  ["🥤", "Bebidas", "1.102 productos"],
  ["🧴", "Hogar y cuidado", "870 productos"],
];

const money = (value: number) => new Intl.NumberFormat("es-CO", { style: "currency", currency: "COP", maximumFractionDigits: 0 }).format(value);

export default function Home() {
  const [cart, setCart] = useState<number[]>([1, 3]);
  const [cartOpen, setCartOpen] = useState(false);
  const [view, setView] = useState<"market" | "dashboard">("market");
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<(typeof products)[number] | null>(null);
  const [favorite, setFavorite] = useState<number[]>([2]);
  const filtered = products.filter((p) => `${p.name} ${p.store}`.toLowerCase().includes(query.toLowerCase()));
  const cartProducts = cart.map((id) => products.find((p) => p.id === id)!).filter(Boolean);
  const total = useMemo(() => cartProducts.reduce((sum, p) => sum + p.price, 0), [cartProducts]);

  const add = (id: number) => {
    setCart((items) => [...items, id]);
    setCartOpen(true);
  };

  return (
    <main>
      <div className="announcement"><span>Envíos gratis desde $80.000</span><span className="announcement-center">Compra local. Recibe mejor.</span><span>Ayuda y soporte</span></div>
      <header className="topbar">
        <button className="brand" onClick={() => setView("market")} aria-label="Ir al inicio">
          <span className="brand-mark">go</span><span>market</span>
        </button>
        <button className="location"><span className="pin">●</span><span><small>Entregar en</small><strong>Bogotá, Chapinero</strong></span><b>⌄</b></button>
        <label className="search"><span>⌕</span><input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="¿Qué necesitas hoy?"/><kbd>⌘ K</kbd></label>
        <nav className="actions">
          <button aria-label="Favoritos">♡</button><button aria-label="Notificaciones">♢<i /></button>
          <button className="profile"><span>JS</span><span><small>Hola, Juan</small><strong>Mi cuenta</strong></span></button>
          <button className="cart-button" onClick={() => setCartOpen(true)}><span>🛒</span><b>{cart.length}</b><strong>{money(total)}</strong></button>
        </nav>
      </header>
      <div className="navrow">
        <div className="navlinks"><button className={view === "market" ? "active" : ""} onClick={() => setView("market")}>Explorar</button><button>Ofertas</button><button>Nuevos</button><button>Tiendas</button><button onClick={() => setView("dashboard")} className={view === "dashboard" ? "active" : ""}>Panel proveedor</button></div>
        <div className="trust"><span>✓ Pagos seguros</span><span>↺ Compra protegida</span></div>
      </div>

      {view === "market" ? (
        <>
          <section className="hero shell">
            <div className="hero-copy"><span className="eyebrow">MERCADO FRESCO · ENTREGA HOY</span><h1>Todo lo bueno,<br/><em>más cerca de ti.</em></h1><p>Compra en tus tiendas favoritas, combina productos en un solo carrito y nosotros coordinamos el resto.</p><div className="hero-actions"><button className="primary">Comprar ahora <span>→</span></button><button className="play"><i>▶</i> Conoce GoMarket</button></div><div className="hero-proof"><span className="avatars"><i>MR</i><i>AS</i><i>LV</i><i>+2k</i></span><span><b>4.9 de 5</b><small>Más de 2.000 compradores felices</small></span></div></div>
            <div className="hero-art" aria-hidden="true"><div className="blob"></div><span className="leaf leaf-one">◆</span><span className="leaf leaf-two">◆</span><div className="bag"><div className="bag-handle"></div><div className="bag-items"><span>🥬</span><span>🥖</span><span>🍅</span></div><b>go</b><small>market</small></div><div className="floating-card card-delivery"><i>⚡</i><span><b>Entrega express</b><small>En menos de 45 min</small></span></div><div className="floating-card card-local"><i>♥</i><span><b>Compra local</b><small>Apoya a tu comunidad</small></span></div></div>
            <div className="dots"><b></b><i></i><i></i></div>
          </section>

          <section className="shell category-section"><div className="section-heading"><div><span className="kicker">ENCUENTRA LO QUE AMAS</span><h2>Compra por categoría</h2></div><button>Ver todas <span>→</span></button></div><div className="category-grid">{categories.map(([icon,name,count]) => <button className="category-card" key={name}><span>{icon}</span><strong>{name}</strong><small>{count}</small><i>→</i></button>)}</div></section>

          <section className="shell products-section"><div className="section-heading"><div><span className="kicker orange">SELECCIÓN PARA TI</span><h2>{query ? `Resultados para “${query}”` : "Favoritos de la semana"}</h2><p>Productos que todos están amando, seleccionados para ti.</p></div><button>Ver todos <span>→</span></button></div><div className="product-grid">{filtered.map((p) => <article className="product-card" key={p.id}><button className={`heart ${favorite.includes(p.id) ? "liked" : ""}`} onClick={() => setFavorite((f) => f.includes(p.id) ? f.filter((id) => id !== p.id) : [...f,p.id])}>♥</button><button className="product-visual" style={{background:p.color}} onClick={() => setSelected(p)}><span>{p.image}</span><b className={p.tag === "Nuevo" || p.tag === "Top" ? "green" : ""}>{p.tag}</b></button><div className="product-info"><div className="rating">★ {p.rating} <span>· {p.unit}</span></div><button className="product-name" onClick={() => setSelected(p)}>{p.name}</button><small>por <b>{p.store}</b> <i>✓</i></small><div className="price"><span><b>{money(p.price)}</b>{p.old && <del>{money(p.old)}</del>}</span><button onClick={() => add(p.id)} aria-label={`Agregar ${p.name}`}>＋</button></div></div></article>)}</div>{filtered.length === 0 && <div className="empty">No encontramos productos con esa búsqueda.</div>}</section>

          <section className="shell value-strip"><div><i>⚡</i><span><b>Entrega rápida</b><small>Recibe el mismo día</small></span></div><div><i>♧</i><span><b>Productos frescos</b><small>Calidad seleccionada</small></span></div><div><i>♡</i><span><b>Apoya lo local</b><small>Compra a comercios cercanos</small></span></div><div><i>✓</i><span><b>Compra segura</b><small>Pagos siempre protegidos</small></span></div></section>
        </>
      ) : <Dashboard />}

      <nav className="mobile-nav"><button onClick={() => setView("market")} className={view === "market" ? "active" : ""}>⌂<small>Inicio</small></button><button>⌕<small>Buscar</small></button><button>▦<small>Categorías</small></button><button onClick={() => setCartOpen(true)}>🛒<small>Carrito</small><b>{cart.length}</b></button><button onClick={() => setView("dashboard")}>○<small>Perfil</small></button></nav>

      {cartOpen && <><button className="overlay" onClick={() => setCartOpen(false)} aria-label="Cerrar carrito"/><aside className="cart-drawer"><div className="drawer-head"><div><span>Tu carrito</span><small>{cart.length} productos · {new Set(cartProducts.map(p => p.store)).size} tiendas</small></div><button onClick={() => setCartOpen(false)}>×</button></div><div className="delivery-progress"><div><span>Te faltan <b>{money(Math.max(0,80000-total))}</b> para envío gratis</span><strong>{Math.min(100, total/800)}%</strong></div><i><b style={{width:`${Math.min(100,total/800)}%`}}/></i></div><div className="cart-items">{cartProducts.map((p,index) => <div className="cart-group" key={`${p.id}-${index}`}><span className="store-label">◉ {p.store} <i>Ver tienda</i></span><div className="cart-item"><span style={{background:p.color}}>{p.image}</span><div><b>{p.name}</b><small>{p.unit}</small><strong>{money(p.price)}</strong></div><div className="quantity"><button onClick={() => setCart((items) => {const next=[...items]; next.splice(index,1); return next;})}>−</button><b>1</b><button onClick={() => setCart((items) => [...items,p.id])}>＋</button></div></div></div>)}</div>{cartProducts.length === 0 && <div className="empty-cart"><span>🛒</span><h3>Tu carrito está esperando</h3><p>Agrega productos frescos y deliciosos.</p></div>}<div className="cart-summary"><div><span>Subtotal</span><b>{money(total)}</b></div><div><span>Domicilio estimado</span><b>{total >= 80000 ? "Gratis" : money(6900)}</b></div><hr/><div className="total"><span>Total</span><b>{money(total + (total && total < 80000 ? 6900 : 0))}</b></div><button className="checkout" disabled={!total}>Continuar al pago <span>→</span></button><small>🔒 Pago seguro y compra protegida</small></div></aside></>}

      {selected && <><button className="overlay" onClick={() => setSelected(null)} aria-label="Cerrar detalle"/><div className="product-modal"><button className="modal-close" onClick={() => setSelected(null)}>×</button><div className="modal-image" style={{background:selected.color}}><span>{selected.image}</span><small>Vista previa del producto</small></div><div className="modal-copy"><span className="kicker">{selected.store}</span><h2>{selected.name}</h2><div className="rating">★ {selected.rating} · 128 opiniones</div><p>Seleccionado por su frescura y calidad. Preparado cuidadosamente por un comercio local de confianza.</p><div className="modal-meta"><span><small>Presentación</small><b>{selected.unit}</b></span><span><small>Disponibilidad</small><b className="stock">En stock</b></span></div><div className="modal-buy"><span><small>Precio</small><b>{money(selected.price)}</b></span><button className="primary" onClick={() => {add(selected.id);setSelected(null)}}>Agregar al carrito</button></div></div></div></>}
    </main>
  );
}

function Dashboard(){
  return <section className="dashboard"><aside className="dash-side"><div className="dash-store"><span>HV</span><div><b>Huerta del Valle</b><small>Plan profesional</small></div></div>{["▦  Resumen","□  Pedidos","◇  Productos","≋  Inventario","♧  Clientes","%  Promociones","↗  Reportes","⚙  Configuración"].map((x,i)=><button className={i===0?"active":""} key={x}>{x}{i===1&&<b>8</b>}</button>)}</aside><div className="dash-main"><div className="dash-title"><div><span className="kicker">DOMINGO, 2 DE AGOSTO</span><h1>Buenos días, Andrés 👋</h1><p>Tu tienda está funcionando bien. Aquí tienes el resumen de hoy.</p></div><button className="primary">＋ Nuevo producto</button></div><div className="metrics"><article><span>Ventas de hoy <i>↗ 12.4%</i></span><b>$1.284.500</b><small>vs. $1.142.000 ayer</small></article><article><span>Pedidos <i>↗ 8.2%</i></span><b>48</b><small>8 pendientes por atender</small></article><article><span>Ticket promedio <i>↗ 3.1%</i></span><b>$26.760</b><small>vs. $25.950 ayer</small></article><article><span>Productos activos</span><b>126</b><small>4 con stock bajo</small></article></div><div className="dash-grid"><article className="chart-card"><div className="card-title"><div><b>Ventas esta semana</b><small>Ingresos diarios</small></div><button>Últimos 7 días ⌄</button></div><div className="chart"><div className="ylabels"><span>$1.5M</span><span>$1M</span><span>$500k</span><span>$0</span></div><div className="bars">{[48,65,58,78,72,92,84].map((h,i)=><span key={i}><i style={{height:`${h}%`}}></i><small>{["Lun","Mar","Mié","Jue","Vie","Sáb","Dom"][i]}</small></span>)}</div></div></article><article className="orders-card"><div className="card-title"><div><b>Pedidos recientes</b><small>Actualizados en tiempo real</small></div><button>Ver todos →</button></div>{[["#GM-2841","Laura Gómez","$84.900","Preparando"],["#GM-2840","Carlos Ruiz","$42.500","Pendiente"],["#GM-2839","María Díaz","$126.800","Despachado"],["#GM-2838","Juan López","$36.200","Entregado"]].map((o)=><div className="order" key={o[0]}><span>{o[1].split(" ").map(n=>n[0]).join("")}</span><div><b>{o[1]}</b><small>{o[0]} · hace 8 min</small></div><strong>{o[2]}</strong><i className={o[3].toLowerCase()}>{o[3]}</i></div>)}</article></div></div></section>
}
