# MoodleQuiz Live

> Quiz interativo em tempo real integrado ao Moodle — professor lança questões ao vivo e os alunos respondem pelo celular ou computador.

---

## O que é isso?

O **MoodleQuiz Live** é um aplicativo web que transforma qualquer Quiz do Moodle em uma atividade ao vivo, estilo *Kahoot*, totalmente integrado com a sua plataforma Moodle existente.

**Para o professor:**
- Escolhe um quiz já cadastrado no Moodle
- Libera as questões uma a uma, com cronômetro configurável (15 a 120 segundos)
- Exibe um QR Code para os alunos acessarem
- Acompanha o ranking em tempo real

**Para o aluno:**
- Acessa uma URL ou escaneia o QR Code
- Faz login com as mesmas credenciais do Moodle
- Responde as questões assim que o professor as libera
- Quanto mais rápido acertar, mais pontos ganha
- Vê o placar ao vivo

Tudo funciona sem instalar nenhum aplicativo — é uma página web acessível de qualquer dispositivo.

---

## Como funciona por baixo dos panos

O aplicativo usa duas atividades do Moodle:

1. **Quiz (mod_quiz):** onde as perguntas de múltipla escolha estão cadastradas. O professor escolhe qual quiz usar na hora de iniciar a sessão ao vivo.

2. **Database (mod_data) chamada `mq_state`:** funciona como uma "lousa compartilhada" entre professor e alunos. O professor escreve nela "liberou a questão X, com Y segundos", e os alunos leem essa informação a cada 2 segundos para saber quando aparecer a questão na tela.

---

## Pré-requisitos

Antes de começar, verifique se você tem:

- Uma instância do Moodle com acesso de administrador
- Uma conta no [GitHub](https://github.com)
- Os alunos precisam ter conta no Moodle (login normal deles)

---

## Parte 1 — Configuração no Moodle

### 1.1 — Habilitar o serviço web para aplicativos móveis

O aplicativo se comunica com o Moodle usando a mesma API que o aplicativo oficial do Moodle (Moodle Mobile). Você precisa garantir que esse serviço está ativo.

1. No painel de administração do Moodle, vá em:
   **Administração do site → Plugins → Serviços web → Gerenciar serviços**

2. Localize o serviço chamado **"Moodle mobile web service"** e verifique se está **habilitado**.

3. Vá em **Administração do site → Plugins → Serviços web → Gerenciar tokens** e confirme que os usuários conseguem gerar tokens para esse serviço.

4. Em **Administração do site → Recursos avançados**, certifique-se de que **"Habilitar serviços web"** está marcado como **Sim**.

> **Resumo:** se o aplicativo oficial do Moodle funciona no seu servidor, esta parte já está feita.

---

### 1.2 — Criar o curso e o Quiz

1. Crie (ou use um já existente) um **curso** no Moodle onde o quiz vai acontecer.

2. Dentro desse curso, adicione uma atividade do tipo **Quiz**.

3. No Quiz, cadastre as questões de **múltipla escolha** que serão usadas ao vivo.
   - Questões dissertativas são ignoradas pelo sistema.
   - Não precisa configurar tempo limite no próprio Quiz — o tempo é controlado pelo app.

4. Anote o **ID do curso**. Você pode encontrá-lo na URL do curso:
   ```
   https://moodle.suainstituicao.br/course/view.php?id=XXXX
                                                        ^^^^
                                                    esse é o ID
   ```

---

### 1.3 — Criar a atividade Database "mq_state"

Esta é a parte mais importante. Você vai criar uma atividade especial que serve de canal de comunicação entre o professor e os alunos.

#### Passo a passo:

1. Dentro do **mesmo curso** do Quiz, clique em **"Adicionar uma atividade ou recurso"**.

2. Escolha **"Base de dados"** (Database).

3. Configure assim:
   - **Nome:** `mq_state` ← **obrigatório exatamente com este nome**
   - **Entradas necessárias antes da visualização:** `0`
   - **Entradas necessárias:** `0`
   - **Máximo de entradas:** `0` (sem limite)
   - **Aprovação necessária:** `Não`
   - Deixe o restante como padrão e salve.

4. Agora você precisa criar **7 campos** dentro dessa base de dados. Clique em **"Campos"** e adicione cada um:

| Nome do campo | Tipo do campo | Observação |
|---|---|---|
| `type` | Texto (entrada simples) | Identifica se é estado ou pontuação |
| `state_json` | Área de texto | Armazena o estado do quiz em JSON |
| `student_id` | Texto (entrada simples) | ID do aluno no Moodle |
| `student_name` | Texto (entrada simples) | Nome completo do aluno |
| `score` | Número | Pontuação total |
| `correct_count` | Número | Questões acertadas |
| `pages` | Área de texto | Páginas respondidas (JSON) |

> **Atenção:** os nomes dos campos devem ser escritos **exatamente como mostrado** (minúsculas, sem espaços, com underline). O app busca esses campos pelo nome.

5. Depois de criar os campos, **não precisa criar nenhum template** — o app faz tudo automaticamente.

---

### 1.4 — Permissões na atividade Database

Para que o app funcione corretamente:

- O **professor** precisa ter permissão para **adicionar e editar entradas** na Database.
- Os **alunos** precisam ter permissão para **adicionar entradas** (para registrar as pontuações).
- Todos precisam poder **visualizar entradas**.

Normalmente, as configurações padrões de papel (role) do Moodle já garantem isso. Se tiver dúvidas, verifique as permissões do módulo Database no curso.

---

## Parte 2 — Publicar o aplicativo no GitHub Pages

### 2.1 — Fazer um fork do repositório

1. Acesse o repositório original: `https://github.com/LASEC-UFU/MoodleQuiz`

2. Clique em **"Fork"** no canto superior direito para criar uma cópia na sua conta do GitHub.

---

### 2.2 — Configurar o token secreto para o deploy

O GitHub Actions usa um token para publicar o site automaticamente. Você precisa colocar esse token nas configurações do seu fork.

1. Vá em **Settings → Secrets and variables → Actions → New repository secret**

2. Crie um secret chamado **`token`** com o valor do seu **Personal Access Token** (PAT) do GitHub.

   Para criar um PAT:
   - Clique na sua foto → **Settings → Developer settings → Personal access tokens → Tokens (classic)**
   - Clique em **"Generate new token (classic)"**
   - Marque a permissão **`repo`** (controle total de repositórios privados e públicos)
   - Copie o token gerado e use como valor do secret `token`

---

### 2.3 — Configurar o arquivo `config.json`

No seu fork, edite o arquivo `assets/config.json` com as informações da sua instalação:

```json
{
  "student_url": "https://SEU-USUARIO.github.io/MoodleQuiz/",
  "moodle_url": "https://moodle.suainstituicao.br",
  "quiz_title": "Quiz Interativo",
  "default_question_time": 30,
  "question_time_options": "15,20,30,45,60,90,120",
  "course_id": 0
}
```

| Campo | O que colocar |
|---|---|
| `student_url` | URL pública onde o app ficará hospedado (GitHub Pages do seu fork) |
| `moodle_url` | URL da sua instância Moodle (sem barra no final) |
| `quiz_title` | Nome que aparece na tela dos alunos enquanto aguardam |
| `default_question_time` | Tempo padrão em segundos para cada questão |
| `question_time_options` | Opções de tempo disponíveis no painel do professor (separadas por vírgula) |
| `course_id` | ID do curso onde estão o Quiz e a Database. Use `0` para o app descobrir automaticamente |

> **Dica:** Se você tiver mais de um curso no Moodle, coloque o ID correto para evitar ambiguidade. Se só tiver um curso com a Database `mq_state`, pode deixar `0`.

---

### 2.4 — Configurar o nome do repositório e base-href

Se você renomear o repositório (o nome padrão é `MoodleQuiz`), precisa atualizar dois lugares:

1. No arquivo `.github/workflows/deploy.yml`, a linha:
   ```
   flutter build web --wasm --release --base-href=/MoodleQuiz/
   ```
   Troque `MoodleQuiz` pelo nome do seu repositório.

2. No `assets/config.json`, atualize o campo `student_url` com a URL correta.

---

### 2.5 — Ativar o GitHub Pages

1. No seu fork, vá em **Settings → Pages**

2. Em **"Source"**, selecione **Branch: `gh-pages`** e pasta **`/ (root)`**

3. Clique em **Save**

---

### 2.6 — Fazer o primeiro deploy

1. Faça qualquer pequena alteração no repositório (ou edite e salve o `config.json`)

2. Faça commit e push para a branch `main`

3. Vá em **Actions** e acompanhe o fluxo de build. Leva entre 5 e 10 minutos na primeira vez.

4. Quando concluir, acesse: `https://SEU-USUARIO.github.io/MoodleQuiz/`

---

## Parte 3 — Usando o aplicativo

### Como o professor usa

1. **Acesse a mesma URL** do aplicativo
2. Entre com **seu login e senha do Moodle**
3. O sistema detecta automaticamente que você é professor (com base no papel no curso)
4. Escolha o **curso** e depois o **Quiz** que vai aplicar
5. Clique em **"Iniciar Quiz"**
6. Mostre o **QR Code** para os alunos (ou envie a URL)
7. Para cada questão:
   - Selecione o **tempo** desejado
   - Clique em **"Liberar Questão"**
   - Aguarde os alunos responderem
   - Use **"Fechar Questão"** para encerrar antes do tempo ou espere o cronômetro zerar
8. No final, clique em **"Encerrar Quiz"**

---

### Como o aluno usa

1. **Escaneie o QR Code** ou acesse a URL informada pelo professor
2. Entre com **seu login e senha do Moodle**
3. Aguarde na tela de espera
4. Quando o professor liberar uma questão, ela aparece automaticamente com o cronômetro
5. Selecione a resposta e clique em **"Enviar"**
   - Se o tempo acabar sem resposta, a questão é marcada como não respondida automaticamente
6. Veja se acertou e acompanhe o placar

---

## Pontuação

O sistema de pontos funciona assim:

- Cada questão vale **1000 pontos base**
- Um bônus de **10 pontos por segundo restante** é adicionado para quem responde rápido
- Questões erradas ou não respondidas valem **0 pontos**
- O ranking mostra a pontuação total acumulada durante toda a sessão

---

## Estrutura do projeto (para desenvolvedores)

```
lib/
├── core/config/        → Configurações globais (app_config.dart)
├── core/router/        → Navegação com GoRouter
├── core/theme/         → Tema visual do app
├── data/datasources/   → Comunicação com Moodle (REST API)
├── data/repositories/  → Implementações dos repositórios
├── domain/entities/    → Entidades de negócio (User, QuizState, Question, Score)
├── domain/usecases/    → Casos de uso (Login, ReleaseQuestion, SubmitAnswer...)
└── presentation/
    ├── controllers/    → Lógica de estado (Provider)
    └── pages/          → Telas do professor e do aluno

assets/
└── config.json         → Configuração editável sem recompilar

.github/workflows/
└── deploy.yml          → Pipeline automático de build e deploy
```

---

## Tecnologias utilizadas

| Tecnologia | Função |
|---|---|
| [Flutter](https://flutter.dev) (Web + WASM) | Framework principal |
| [Provider](https://pub.dev/packages/provider) | Gerenciamento de estado |
| [GoRouter](https://pub.dev/packages/go_router) | Navegação |
| [http](https://pub.dev/packages/http) | Chamadas à API do Moodle |
| [shared_preferences](https://pub.dev/packages/shared_preferences) | Sessão local |
| [flutter_widget_from_html](https://pub.dev/packages/flutter_widget_from_html) | Renderiza HTML das questões do Moodle |
| GitHub Actions | Build e deploy automático |
| GitHub Pages | Hospedagem gratuita |

---

## Problemas comuns

**O aluno fica preso na tela de espera mesmo após o professor liberar a questão**
- Verifique se o `course_id` em `config.json` está correto
- Confirme que a Database `mq_state` existe no curso e tem todos os 7 campos

**Aparece erro "Function not authorized"**
- Verifique se o serviço `moodle_mobile_app` está habilitado no Moodle
- Confirme que o usuário tem permissão de acesso ao webservice

**O professor não consegue liberar a questão**
- Confirme que o professor tem permissão para **adicionar e editar entradas** na Database `mq_state`
- A requisição de escrita usa POST — certifique-se de que o servidor Moodle não bloqueia esse método

**A tela em branco aparece ao abrir pelo QR Code**
- Verifique se o `base-href` no `deploy.yml` corresponde ao nome do seu repositório
- Confirme que o GitHub Pages está apontando para a branch `gh-pages`

---

## Licença

Desenvolvido pelo **LASEC — Laboratório de Sistemas Embarcados e Computação** da Universidade Federal de Uberlândia (UFU).
