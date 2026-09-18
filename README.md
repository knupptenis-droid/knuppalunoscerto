# Vagas de reposição — Knupp Tênis

Site para liberar vagas avulsas de reposição. Você abre uma rodada com X vagas, manda o link no WhatsApp, e quem preenche primeiro garante o lugar. Quando as vagas acabam, o formulário fecha sozinho.

É um site só. O painel do professor abre pela engrenagem no canto inferior direito, protegido por senha — mesmo esquema do site de lista de espera. O aluno pode até clicar nela; sem a senha não passa da tela de login.

---

## 1. Supabase (projeto novo)

1. Crie um projeto novo em supabase.com.
2. **SQL Editor** → cole o conteúdo de `schema.sql` → **Run**.
3. **Project Settings → API**, anote:
   - **Project URL** → vira `SUPABASE_URL`
   - **service_role key** (a secreta, não a `anon`) → vira `SUPABASE_SERVICE_KEY`

A `service_role` só vive no servidor do Render. Ela nunca aparece no navegador do aluno.

## 2. GitHub

Suba esta pasta num repositório novo (pode ser privado).

## 3. Render

1. **New → Web Service** → conecte o repositório.
2. Runtime **Node**, Build Command `npm install`, Start Command `npm start`.
3. Em **Environment**, crie:

| Chave | Valor |
|---|---|
| `SUPABASE_URL` | a URL do passo 1 |
| `SUPABASE_SERVICE_KEY` | a service_role key |
| `ADMIN_SENHA` | a senha que só você vai usar no `/admin` |

4. Deploy. O Render te dá uma URL. Se quiser, aponte um subdomínio (ex.: `reposicao.knupptenis.com.br`) em **Settings → Custom Domain**.

> No plano gratuito do Render o serviço hiberna sem uso e a primeira visita demora ~30s para abrir. Se for mandar o link para 60 alunos de uma vez, vale abrir você mesmo antes de enviar a mensagem.

---

## Uso no dia a dia

1. Abra o site, clique na engrenagem no canto e digite a senha.
2. **Abrir nova rodada**: título (ex.: *Sábado, 14/03 — 8h no Clube Militar*), detalhe opcional e o número de vagas.
3. Copie o link da página principal e mande no grupo.
4. Volte no painel para ver quem entrou. Dá para aumentar/diminuir vagas, encerrar na mão, remover alguém (libera a vaga de volta) e copiar a lista pronta para colar no WhatsApp.
5. Semana seguinte: abra outra rodada. A página do aluno passa a mostrar a nova; as inscrições antigas continuam salvas no Supabase.

Só existe uma rodada ativa por vez — a mais recente. É o modelo de pool único que você pediu.

## Detalhe técnico que importa

A inscrição não é feita com "lê o total, depois grava". Ela passa por uma função no banco (`inscrever`) que trava a linha da rodada, conta e só então insere. Se dois alunos apertarem o botão no mesmo segundo pela última vaga, um entra e o outro recebe "as vagas acabaram de ser preenchidas" — nunca os dois.
