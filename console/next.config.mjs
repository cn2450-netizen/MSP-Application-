const host = process.env.CONSOLE_HOST || "localhost";
const mesh = process.env.MESH_HOST ? `https://${process.env.MESH_HOST}` : "";

/** @type {import('next').NextConfig} */
const nextConfig = {
  poweredByHeader: false,
  reactStrictMode: true,
  // Server actions are only accepted from the console's own public origin (NPM forwards the Host header).
  experimental: { serverActions: { allowedOrigins: [host] } },
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "Strict-Transport-Security", value: "max-age=31536000; includeSubDomains" },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "X-Frame-Options", value: "DENY" },
          { key: "Referrer-Policy", value: "same-origin" },
          { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
          { key: "Cache-Control", value: "no-store" },
          {
            key: "Content-Security-Policy",
            // frame-src lets the Connect page show MeshCentral's viewer, and nothing else, inside the console.
            value: `default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-src ${mesh || "'none'"}; frame-ancestors 'none'; form-action 'self'; base-uri 'self'`,
          },
        ],
      },
    ];
  },
};

export default nextConfig;
