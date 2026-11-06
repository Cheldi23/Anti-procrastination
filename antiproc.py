#!/usr/bin/env python3
import socket, struct, ssl, threading, subprocess, signal, sys
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

CIBLE    = "https://www.coursera.org/"
UPSTREAM = ("127.0.0.1", 53)
CERT, KEY = "/etc/antiproc/cert.pem", "/etc/antiproc/key.pem"

# ---------- DNS ----------
def lire_question(data):
    i, labels = 12, []
    while data[i]:
        n = data[i]; labels.append(data[i+1:i+1+n].decode()); i += n + 1
    qtype = struct.unpack(">H", data[i+1:i+3])[0]
    return ".".join(labels).lower(), qtype, i + 5

def dns_reso(nom):
    """Retourne 127.0.0.1 pour Facebook, None sinon (résolution normale)."""
    if nom == "facebook" or nom == "facebook.com" or nom.endswith(".facebook.com"):
        return "127.0.0.1"
    return None

def repondre(data, k, qtype, fin):
    tid = data[:2]
    question = data[12:fin]
    if qtype == 1:        # A : on renvoie l'IP locale
        entete = tid + struct.pack(">HHHHH", 0x8180, 1, 1, 0, 0)
        reponse = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 30, 4) + socket.inet_aton(k)
    else:                 # AAAA etc. : réponse vide, le navigateur retombe sur IPv4
        entete = tid + struct.pack(">HHHHH", 0x8180, 1, 0, 0, 0)
        reponse = b""
    return entete + question + reponse

def traiter(data, addr, sock):
    try:
        nom, qtype, fin = lire_question(data)
        k = dns_reso(nom)
        if k:
            sock.sendto(repondre(data, k, qtype, fin), addr)
        else:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as up:
                up.settimeout(3); up.sendto(data, UPSTREAM)
                sock.sendto(up.recv(4096), addr)
    except Exception:
        pass

def serveur_dns():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.2", 53))
    while True:
        data, addr = sock.recvfrom(4096)
        threading.Thread(target=traiter, args=(data, addr, sock), daemon=True).start()

# ---------- Redirection HTTP/HTTPS ----------
class Redirect(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(302); self.send_header("Location", CIBLE); self.end_headers()
    do_HEAD = do_POST = do_GET
    def log_message(self, *a): pass

def serveur_web(port, tls):
    srv = ThreadingHTTPServer(("127.0.0.1", port), Redirect)
    if tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(CERT, KEY)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()

# ---------- Configuration système ----------
def interface():
    t = subprocess.check_output(["ip", "route", "show", "default"], text=True).split()
    return t[t.index("dev") + 1]

def main():
    itf = interface()
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    for port, tls in ((80, False), (443, True)):
        threading.Thread(target=serveur_web, args=(port, tls), daemon=True).start()
    subprocess.run(["resolvectl", "dns", itf, "127.0.0.2"])
    subprocess.run(["resolvectl", "domain", itf, "~."])
    try:
        serveur_dns()
    finally:
        subprocess.run(["resolvectl", "revert", itf])   # rétablit le DNS d'origine

if __name__ == "__main__":
    main()
