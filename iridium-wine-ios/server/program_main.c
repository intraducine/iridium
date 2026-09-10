/*
 * Standalone wineserver program entry point.
 *
 * Keeping this wrapper separate lets the iOS build archive the native server
 * implementation without pulling a second `main` symbol into the app.
 */

extern int wine_server_main( int argc, char *argv[] );

int main( int argc, char *argv[] )
{
    return wine_server_main( argc, argv );
}
