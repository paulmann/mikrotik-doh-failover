# -*- coding: utf-8 -*-
"""Apply post-verification corrections to article 3315 content."""
from pathlib import Path

base = Path(__file__).parent
src = base / "_work-article-3315-current.html"
out = base / "_work-article-3315-final.html"

c = src.read_text(encoding="utf-8")

# ---- R1: prominent GitHub link, right before section 1 heading ----
intro_anchor = (
    '<!-- wp:heading -->\n'
    '<h2 class="wp-block-heading"><strong>1. Введение: Эволюция безопасности DNS в эпоху RouterOS v7</strong></h2>\n'
    '<!-- /wp:heading -->'
)
github_block = (
    '<!-- wp:paragraph -->\n'
    '<p><strong>Исходники и обновления:</strong> <a href="https://github.com/paulmann/mikrotik-doh-failover">github.com/paulmann/mikrotik-doh-failover</a> — проверяемые <code>.rsc</code>-скрипты, схемы и changelog. Команды ниже проверены на RouterOS 7.23.1 и 7.24.5 (Cloudflare Family DoH).</p>\n'
    '<!-- /wp:paragraph -->\n\n'
)
assert c.count(intro_anchor) == 1, f"intro anchor count={c.count(intro_anchor)}"
c = c.replace(intro_anchor, github_block + intro_anchor)

# ---- R2: section 6.2 — add the builtin-trust-store finding ----
old_62 = (
    'Для семейного фильтра (1.1.1.3 / 1.0.0.3) endpoint один: '
    '<code>https://family.cloudflare-dns.com/dns-query</code>.</p>'
)
new_62 = (
    'Для семейного фильтра (1.1.1.3 / 1.0.0.3) endpoint один: '
    '<code>https://family.cloudflare-dns.com/dns-query</code>. '
    'Важно: встроенное хранилище (<code>/certificate settings builtin-trust-store=default</code>) '
    'цепочку Cloudflare на 7.23/7.24 <strong>не покрывает</strong>, а параметра '
    '<code>builtin-trust-anchors</code> не существует — импорт CA обязателен (проверено).</p>'
)
assert c.count(old_62) == 1, f"6.2 anchor count={c.count(old_62)}"
c = c.replace(old_62, new_62)

# ---- R3: insert the :resolve server= note before section 6.7 ----
old_67 = (
    '<!-- wp:heading {"level":3} -->\n'
    '<h3 class="wp-block-heading"><strong>6.7. use-doh-server — единственный путь: без фейловера резолв встаёт</strong></h3>\n'
    '<!-- /wp:heading -->'
)
new_67 = (
    '<!-- wp:paragraph -->\n'
    '<p>Параметр <code>server=</code> у <code>:resolve</code> поддерживается (проверено на 7.23.1/7.24.5), '
    'а <code>timeout=</code> — нет (<code>bad parameter timeout</code>).</p>\n'
    '<!-- /wp:paragraph -->\n\n' + old_67
)
assert c.count(old_67) == 1, f"6.7 anchor count={c.count(old_67)}"
c = c.replace(old_67, new_67)

# ---- R4: soften the conclusion overclaim + add honest formulation ----
old_claim = (
    'Благодаря правилам DST-NAT, клиенты физически не могут обойти заданную конфигурацию.'
)
new_claim = (
    'Благодаря правилам redirect классический DNS-трафик LAN идёт на роутер; '
    'при этом клиентский DoH/DoT это не блокирует.'
)
assert c.count(old_claim) == 1, f"claim anchor count={c.count(old_claim)}"
c = c.replace(old_claim, new_claim)

old_final = (
    '<p>Данная система является <strong>продуманной инженерной конструкцией</strong>, где каждый компонент обоснован, '
    'проверен на совместимость с v7.20.6 и готов к масштабированию. Она реализует принципы '
    '<strong>infrastructure as code</strong> в экосистеме MikroTik, обеспечивая предсказуемость, '
    'воспроизводимость и надежность в корпоративных сетях.</p>'
)
new_final = (
    '<p>Честно о границах решения: оно шифрует DNS-трафик маршрутизатора через один DoH-апстрим, '
    'контролирует его доступность и при сбое временно переключается на обычные семейные DNS-серверы. '
    'Оно перенаправляет классический DNS-трафик LAN к роутеру, но <strong>не предотвращает</strong> '
    'использование клиентского DoH/DoT — для этого нужны дополнительные политики блокировки.</p>\n'
    '<!-- /wp:paragraph -->\n\n'
    '<!-- wp:paragraph -->\n'
    '<p>Готовые проверяемые скрипты, схемы и changelog — в репозитории '
    '<a href="https://github.com/paulmann/mikrotik-doh-failover">github.com/paulmann/mikrotik-doh-failover</a>. '
    'Там же принимаются отчёты о несовместимости с другими конфигурациями MikroTik.</p>'
)
assert c.count(old_final) == 1, f"final anchor count={c.count(old_final)}"
c = c.replace(old_final, new_final)

c = c.replace("\r\n", "\n")
out.write_text(c, encoding="utf-8", newline="\n")
print("corrections applied; output bytes:", out.stat().st_size)
