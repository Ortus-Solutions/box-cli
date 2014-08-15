/**
* This will create a new xUnit test bundle in the requested folder but you can 
* override that with the directory param as well.
*  
**/
component extends="commandbox.system.BaseCommand" aliases="" excludeFromHelp=false {
	
	/**
	* @name.hint Name of the xUnit bundle to create without the .cfc. For packages, specify name as 'myPackage/MyTest'
	* @open.hint Open the file once it is created
	* @directory.hint The base directory to create your CFC
	 **/
	function run( required name, boolean open=false, directory=shell.pwd() ){
		// This will make each directory canonical and absolute		
		arguments.directory = fileSystemUtil.resolvePath( arguments.directory );
						
		// Validate directory
		if( !directoryExists( arguments.directory ) ) {
			// create the directory 
			directoryCreate( arguments.directory );			
		}
		
		// Allow dot-delimited paths
		arguments.name = replace( arguments.name, '.', '/', 'all' );
		
		// This help readability so the success messages aren't up against the previous command line
		print.line();
		
		// Read in Templates
		var content = fileRead( '/commandbox/templates/testbox/unit.txt' );
				
		// Write out BDD Spec
		var thisPath = '#directory#/#name#.cfc'; 
		file action='write' file='#thisPath#' mode ='777' output='#content#';
		print.greenLine( 'Created #thisPath#' );

		// Open file?
		if( arguments.open ){ runCommand( "edit #thisPath#" ); }			
	}

}