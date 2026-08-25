/* Conexión con Supabase para el ranking por grupos.

   Rellena estos dos valores con los de tu proyecto:
   Supabase → Project Settings → Data API (o API Keys)
     · SUPABASE_URL  →  "Project URL"
     · SUPABASE_KEY  →  la clave pública (anon / publishable)

   La clave anon está pensada para ir en el navegador, no es una
   contraseña: las tablas están cerradas con RLS y sólo se puede entrar
   por las funciones de supabase.sql. Aun así, no pongas aquí nunca la
   clave "service_role", que esa sí lo abre todo.

   Mientras estén sin rellenar, la app funciona igual pero el ranking
   aparece desactivado. */

window.DEEPWORK_CONFIG = {
  SUPABASE_URL: "https://gsoxelgpexrqyazhedye.supabase.co",
  SUPABASE_KEY: "sb_publishable_Yd_MGdwPyHinS2x3MsAD0Q_CEFacCgk"
};
