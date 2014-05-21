/**
 * Show server status
 **/
component extends="commandbox.system.BaseCommand" aliases="status" excludeFromHelp=false {

	/**
	 * Show server status
	 *
	 * @directory.hint web root for the server
	 * @name.hint short name for the server
	 **/
	function run( String directory="", String name="" ){
		var manager = new commandbox.system.services.ServerService( shell );
		var servers = manager.getServers();

		arguments.directory = fileSystemUtil.resolveDirectory( arguments.directory );

		for(var serverKey in servers ){
			var serv = servers[ serverKey ];
			if( arguments.directory != "" && serv.webroot != arguments.directory )
				continue;
			if( arguments.name != "" && serv.name != arguments.name )
				continue;
			if( isNull( serv.statusInfo.reslut ) ){
				serv.statusInfo.reslut = "";
			}

			print.yellowLine( "name: " & serv.name );
			print.string("  status: " );

			if(serv.status eq "running") {
				print.greenLine( "running" );
				print.line( "  info: " & serv.statusInfo.reslut );
			} else if (serv.status eq "starting") {
				print.yellowLine( "starting" );
				print.redLine("  info: " & serv.statusInfo.reslut );
			} else if (serv.status eq "unknown") {
				print.redLine( "unknown" );
				print.redLine("  info: " & serv.statusInfo.reslut );
			} else {
				print.Line(serv.status);
			}

			print.Line("  webroot: " & serv.webroot );
			print.Line("  port: " & serv.port );
			print.Line("  stopsocket: " & serv.stopsocket );
		}
	}

}