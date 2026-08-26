# Deep Work

Registro diario de trabajo profundo. Una web autocontenida que se puede
instalar como app en el móvil y funciona sin conexión.

- `index.html` — la app entera
- `config.js` — claves de Supabase para el ranking (opcional)
- `supabase.sql` — la base de datos del ranking
- `sw.js`, `manifest.json`, `icon-*.png` — lo que la hace instalable

## Dónde viven los datos

En el dispositivo, siempre. La app guarda tu registro en tres sitios a la
vez (localStorage, una copia de seguridad e IndexedDB) y al arrancar los
fusiona, de forma que si el navegador borra uno, el historial se recompone
solo. Además pide almacenamiento persistente para que no lo borre por
inactividad.

**Instálala en la pantalla de inicio.** El navegador sólo concede
almacenamiento permanente de verdad a las apps instaladas; en una pestaña
suelta la protección es menor.

Desde el pie de la app puedes **Exportar** una copia en JSON e
**Importar**la en otro dispositivo. Al importar se fusiona, no se
sobrescribe: nunca pierdes días.

## Ranking por grupos (opcional)

Sin configurar, la app funciona igual y el ranking sale desactivado.
Para activarlo:

1. Crea un proyecto gratis en [supabase.com](https://supabase.com).
2. Abre **SQL Editor → New query**, pega entero `supabase.sql` y pulsa Run.
   Se puede volver a ejecutar sin miedo: no borra datos.
3. Ve a **Project Settings → Data API**, copia la *Project URL* y la clave
   pública (*anon* / *publishable*), y ponlas en `config.js`.

Luego, desde la app: **Crear un grupo** te da un código de 6 letras. Quien
lo tenga entra con **Tengo un código** y elige un apodo. También hay
grupos abiertos, a los que se entra sin código desde el chip de grupo.

## Entrar con Google (recomendado)

Sin cuenta, quién eres dentro de un grupo se guarda **sólo en el
dispositivo**. Cuando el navegador borra sus datos —cosa que iOS y Android
hacen con las PWA que llevan días sin abrirse— la app se queda sin grupo,
vuelves a entrar y **apareces duplicado**: la fila vieja se queda con tus
horas. Con la cuenta la identidad la pone el servidor, así que es la misma
en todos tus dispositivos y no puede duplicarse.

Para activarlo:

1. En **Google Cloud Console** → *APIs y servicios* → *Credenciales*, crea
   un **ID de cliente de OAuth** de tipo *Aplicación web*.
   - En *URI de redireccionamiento autorizados* pon exactamente:
     `https://TU-PROYECTO.supabase.co/auth/v1/callback`
     (lo tienes tal cual en el paso 2, Supabase te lo enseña).
2. En **Supabase** → *Authentication* → *Sign In / Providers* → **Google**:
   actívalo y pega el *Client ID* y el *Client Secret* de Google.
3. En **Supabase** → *Authentication* → *URL Configuration*:
   - *Site URL*: la dirección de tu app (por ejemplo
     `https://204aleex.github.io/Deepwork/`).
   - En *Redirect URLs* añade esa misma dirección.

## Entrar con el correo

Además de Google, se puede entrar con el correo sin configurar nada más:
la app pide un código de seis cifras a Supabase y tú lo escribes. Si tu
plantilla de correo de Supabase manda un enlace en vez de un código,
también vale: al pulsarlo se vuelve a la app ya dentro.

Para que llegue el código en vez del enlace, en **Supabase →
Authentication → Emails → Magic Link** añade `{{ .Token }}` a la
plantilla. No es obligatorio.

Con eso, el botón **Entrar** de la app ya funciona. Al iniciar sesión:

- Tu grupo se recupera solo en cualquier dispositivo, sin volver a entrar.
- Volver a entrar en un grupo con otro apodo **te cambia el nombre**, no
  crea un segundo tú.
- Si ya estabas en un grupo sin cuenta, tu fila de siempre se engancha a
  la cuenta en la primera sincronización. No pierdes el historial ni hay
  que volver a entrar.

La app sigue funcionando sin cuenta: el cronómetro y el registro diario son
locales y no la necesitan para nada.

## Limpiar duplicados antiguos

Si arrastras filas duplicadas de antes de las cuentas, quien creó el grupo
puede quitarlas desde **Ajustes → Quitar a alguien**. Se borra esa fila y
sus horas de ese grupo; el registro en el dispositivo de esa persona no se
toca.

### Cómo está protegido

La clave *anon* viaja dentro del navegador, así que cualquiera puede
leerla. Por eso las tablas están cerradas con RLS y sin políticas: no se
tocan directamente. Todo pasa por unas funciones que son la única puerta.

- **El código del grupo es la contraseña compartida.** Sin él no se puede
  leer el ranking de nadie.
- **Cada miembro tiene un secreto propio**, guardado sólo en su
  dispositivo, que es lo que le permite escribir sus minutos y los de
  nadie más.
- No pongas nunca en `config.js` la clave `service_role`: esa sí lo abre
  todo.

Como el registro es por apodo y sin contraseña, cualquiera del grupo puede
inflar sus números a mano. Es un marcador entre conocidos, no una
competición con árbitro.

## Verlo en local

El servidor de la carpeta padre sirve todas las webs a la vez:

```bash
node .claude/servidor.js .
```

Queda en `http://localhost:4173/Deepwork%20App/`.
