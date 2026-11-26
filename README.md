# Atualização v5: plano trimestral + mensalidade no cartão
1. **Supabase:** rode **`atualizacao-v5.sql`**. Precisa do v3 e do v4 já rodados, e não apaga nada.
2. **GitHub:** envie os arquivos da raiz em `.../upload/main` e os da pasta public em `.../upload/main/public`.
3. **Render:** clique em **Manual Deploy → Deploy latest commit**.

---

# Atualização v4: comprar aulas + loja
1. **Supabase → SQL Editor:** rode **`atualizacao-v4.sql`**. Ele não apaga nada e precisa do v3 já rodado.
2. **GitHub:** envie os arquivos da raiz em `.../upload/main` e os da pasta `public` em `.../upload/main/public`.
3. **Painel → Loja → Produtos:** clique em **"Importar da loja antiga"** para trazer os produtos da lojaknupptenis.netlify.app.

---

# Knupp Tênis · Área do Aluno (v3)

O site virou a **Área do Aluno** completa:
- **Aluno** (entra com WhatsApp + PIN de 4 números):
  - Início: próxima aula, avisos, créditos, status da mensalidade, aulas seguidas e indique um amigo;
  - Aulas: turma fixa e diário (tema, recado do professor, avaliação da aula);
  - Reposição (só com a mensalidade em dia);
  - Financeiro: PIX com QR Code e copia-e-cola, "Já paguei" e recibos;
  - Evolução: gráfico de habilidades, checklist para subir de nível, conquistas e conteúdos.
- **Professor**:
  - Hoje: chamada, diário, lembretes e cancelamento por chuva;
  - Turmas fixas, Financeiro do mês, ficha do aluno com avaliação técnica;
  - Conteúdo, avisos e indicações;
  - PIX e critérios de nível em Ajustes.

## Como atualizar um site que já está no ar (v2 → v3)
1. **Supabase → SQL Editor → New query**: cole o arquivo **`atualizacao-v3.sql`** inteiro e clique em **Run**. Ele **não apaga nada**.
   **Nunca** rode o `schema.sql` de novo: ele apaga tudo e só serve para a primeira instalação.
2. **GitHub, arquivos da raiz:** em `github.com/knupptenis-droid/knuppalunoscerto/upload/main`, envie `server.js`, `atualizacao-v3.sql`, `schema.sql` e `README.md`.
3. **GitHub, arquivos da pasta public:** em `github.com/knupptenis-droid/knuppalunoscerto/upload/main/public`, envie `index.html`, `qrcode.js`, `sw.js` e `manifest.webmanifest`.
4. Espere o **Live** no Render.
5. No painel, faça os primeiros ajustes:
   - **Ajustes → PIX e financeiro:** tipo e chave PIX, e o mês em que o financeiro começa (padrão: o mês que vem).
   - **Turmas:** crie as turmas fixas.
   - **Alunos:** confira a mensalidade de cada um. Os valores vieram dos prints do TennisCoach.

---

# (Histórico) Reposições 2.0

Site de reposição de aulas com **créditos**. O aluno entra pelo WhatsApp, vê quantos créditos tem e pede uma vaga. Você confirma pelo WhatsApp com um toque.

- **Aluno:** entra com o WhatsApp → vê os créditos e a validade → vê só as vagas do nível dele → pede a vaga → aguarda sua confirmação. Pode cancelar: antes da confirmação o crédito volta, depois ele perde o crédito.
- **Professor (engrenagem no canto):**
  - **Pedidos:** confirmar e recusar pedidos, e "Avisar o grupo".
  - **Horários:** criar, editar, fechar, duplicar, cancelar por chuva e apagar.
  - **Alunos:** cadastro com WhatsApp, níveis e turmas.
  - **Créditos:** dia de chuva e crédito avulso.
  - **Números:** estatísticas.
  - **Ajustes:** regras, foto, mensagens e níveis.
- **Abertura automática:** cada horário aparece sozinho na **véspera às 14h**. Segunda abre no domingo, e sexta e sábado não abrem nada.
- **Crédito vale 40 dias.** Se a reposição for cancelada por chuva, o crédito volta.
- Os 58 alunos dos seus prints já vêm cadastrados, **sem WhatsApp**. Complete pelo painel: Alunos → filtro "Sem WhatsApp".

---

## Passo a passo para colocar no ar (cerca de 15 minutos)

Faça os passos **1 e 2 em seguida**, um logo depois do outro. Entre eles o site fica fora do ar por alguns minutos.

### 1. Supabase: criar o banco novo
1. Entre em **supabase.com** e abra o **mesmo projeto** do site de reposição atual.
2. No menu da esquerda, clique em **SQL Editor** → **New query**.
3. Abra o arquivo `schema.sql`, copie **tudo** (Ctrl+A, Ctrl+C) e cole lá.
4. Clique em **Run**. No fim tem que aparecer `"importados" : 58`.

> Isso apaga as inscrições antigas de teste. Você disse que podia.

### 2. GitHub: trocar os arquivos
No repositório **knuppalunoscerto**:
1. Clique em **Add file → Upload files**.
2. Arraste **todos** os arquivos desta pasta, mantendo a pasta `public`:
   - `server.js`, `package.json`, `schema.sql`, `README.md`
   - pasta `public/` com: `index.html`, `manifest.webmanifest`, `sw.js`, `icon-192.png`, `icon-512.png`, `apple-touch-icon.png`
3. **Confira os nomes** antes de confirmar. Da outra vez, um arquivo virou "indexsss.html". O nome precisa ser exatamente `index.html`.
4. Clique em **Commit changes**.

### 3. Render: só esperar
- O Render faz o deploy sozinho, em 2 a 4 minutos.
- As variáveis continuam **as mesmas**: `SUPABASE_URL`, `SUPABASE_SERVICE_KEY` e `ADMIN_SENHA`.
- Se não começar sozinho, clique em **Manual Deploy → Deploy latest commit**.
- Para testar, abra **reposicao.knupptenis.com.br**, clique na engrenagem e entre com a sua senha.

### 4. Manter o site acordado às 14h (grátis)
O plano grátis do Render "dorme" depois de 15 minutos sem visitas, e leva até 1 minuto para acordar. Para isso não acontecer na hora da abertura:
1. Crie uma conta grátis em **cron-job.org**.
2. Clique em **Create cronjob**.
3. **URL:** `https://reposicao.knupptenis.com.br/ping`
4. **Execution schedule:** a cada **10 minutos**. Se quiser economizar horas do Render, escolha "Custom" e marque só as horas de **13 a 23**.
5. Salve. Pronto: o site fica acordado e responde na hora.

> O Render dá 750 horas grátis por mês para a conta toda. Um site acordado o mês inteiro usa cerca de 744. Por isso, se você também tem o site da lista de espera no Render grátis, deixe o "ping" só das 13h às 23h.

### 5. Primeiros ajustes no painel
1. **Ajustes:**
   - seu WhatsApp (vira o botão para os alunos);
   - endereço do Clube Militar;
   - **foto**;
   - revise as regras e as mensagens.
2. **Alunos:** cadastre o WhatsApp de cada um. Para as crianças, use o número do responsável. Se o mesmo número for de dois irmãos, o site pergunta "Quem vai jogar?".
3. **Turmas fixas** (opcional, mas recomendado): no cadastro do aluno, escreva por exemplo `Ter 18h, Qui 18h`. No dia de chuva, você marca a turma inteira com um toque.

---

## Rotina do dia a dia
1. **Choveu?** Vá em Créditos → **Lançar créditos de chuva** → escolha a(s) turma(s) → confirmar. Cada aluno ganha 1 crédito.
2. **Criar vagas:** em Horários → **+ Novo horário**, preencha dia, hora, nível(eis) e vagas. Ele abre sozinho na véspera às 14h. Também dá para escolher "Abrir agora".
3. **Às 14h:** em Pedidos → **Avisar o grupo**, escolha o grupo e envie.
4. **Pedidos chegando:** toque em **Confirmar** e o WhatsApp abre com a mensagem pronta. É só enviar.
5. **Choveu na reposição?** No horário, toque em **Cancelar (chuva)**. Os créditos voltam e aparece a lista para avisar cada aluno.
