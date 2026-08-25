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
lo tenga entra con **Tengo un código** y elige un apodo. El ranking se
puede ordenar por hoy, por semana o por total.

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
