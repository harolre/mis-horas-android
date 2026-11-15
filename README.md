# Mis Horas para Android

Aplicación Android nativa hecha con Flutter. Registra jornadas, organiza las
horas por cuenta y calcula objetivos y horas extra. La información se guarda en
SQLite en el dispositivo; no necesita cuenta, servidor ni conexión a internet.

## Funciones disponibles

- Resumen semanal con progreso, objetivo y horas extra.
- Registro, edición y eliminación de tramos; pausas y jornadas que cruzan
  medianoche.
- Estados diarios de trabajo, vacaciones, festivo y baja, además de notas.
- Adjuntos locales de imágenes y PDF, con vista de imágenes, apertura externa y
  uso de la hoja nativa para compartir. El límite actual es 10 MB por adjunto.
- Cuentas con nombre, color, horas acumuladas y archivado.
- Objetivos configurables por día de la semana e inicio de semana configurable.
- Calendario mensual con horas, ausencias y excepciones de objetivo por fecha.
- Resúmenes semanal, mensual y anual, con horas por cuenta.
- Copias cifradas con contraseña en formato móvil `MHBK2` (`.mhbackup`), con
  lectura y escritura por bloques. Al importar, la copia reemplaza los datos
  locales tras confirmación. No es compatible con copias de la versión web.

Los datos permanecen en el dispositivo. Desinstalar la aplicación puede
eliminarlos; exporta copias con regularidad y guarda la contraseña por separado.

## Desarrollo

Requisitos: Flutter SDK y Android SDK instalados.

```powershell
flutter pub get
flutter analyze
flutter test
flutter run
```

En este equipo, si Flutter no está en `PATH`, se puede usar:

```powershell
& "C:\src\flutter\bin\flutter.bat" run
```

## Compilación

APK de depuración:

```powershell
flutter build apk --debug
```

Salida: `build/app/outputs/flutter-apk/app-debug.apk`.

Para Google Play se publicará un Android App Bundle firmado:

```powershell
flutter build appbundle --release
```

La firma de publicación y la ficha de Play Console aún deben configurarse antes
de distribuir la app.
