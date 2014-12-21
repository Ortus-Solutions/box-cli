/**
*********************************************************************************
* Copyright Since 2005 ColdBox Platform by Ortus Solutions, Corp
* www.coldbox.org | www.ortussolutions.com
********************************************************************************
* @author Brad Wood, Luis Majano, Denny Valliant
*
* I handle initializing, reading, and running commands
*/
component accessors="true" singleton {

	// DI Properties
	property name='shell' 				inject='Shell';
	property name='parser' 				inject='Parser';
	property name='system' 				inject='System@constants';
	property name='cr' 					inject='cr@constants';
	property name='logger' 				inject='logbox:logger:{this}';
	property name='wirebox' 			inject='wirebox';
	property name='commandLocations'	inject='commandLocations@constants';
	
	// TODO: Convert these to properties
	instance = {
		// A nested struct of the registered commands
		commands = {},
		// The same command data, but more useful for help and such
		flattenedCommands = {},
		// A stack of running commands in case one command calls another from within
		callStack = []
	};

	/**
	 * Constructor
	 **/
	function init() {
		return this;
	}

	function configure() {
		// map commands
		for( var commandLocation in commandLocations ) {
			
			// Ensure location exists
			if( !directoryExists( expandPath( commandLocation ) ) ) {
				directoryCreate( expandPath( commandLocation ) );				
			}
			// Load up any commands
			initCommands( commandLocation, commandLocation );
		}
	}

	/**
	 * Initialize the commands. This will recursively call itself for subdirectories.
	 * @baseCommandDirectory.hint The starting directory
	 * @commandDirectory.hint The current directory we've recursed into
	 * @commandPath.hint The dot-delimted path so far-- only used when recursing
	 **/
	function initCommands( baseCommandDirectory, commandDirectory, commandPath='' ) {
		var varDirs = DirectoryList( path=commandDirectory, recurse=false, listInfo='query', sort='type desc, name asc' );
		for( var dir in varDirs ){

			// For CFC files, process them as a command
			if( dir.type  == 'File' && listLast( dir.name, '.' ) == 'cfc' ) {
				registerCommand( baseCommandDirectory, dir.name, commandPath );
			// For folders, search them for commands
			} else {
				initCommands( baseCommandDirectory, dir.directory & '\' & dir.name, listAppend( commandPath, dir.name, '.' ) );
			}

		}

	}

	private function createCommandData( required fullCFCPath, required commandName ) {
		var commandMD = getComponentMetadata( fullCFCPath ); 
		
		// Set up of command data
		var commandData = {
			fullCFCPath = arguments.fullCFCPath,
			aliases = listToArray( commandMD.aliases ?: '' ),
			parameters = [],
			completor = {},
			hint = commandMD.hint ?: '',
			originalName = commandName,
			excludeFromHelp = commandMD.excludeFromHelp ?: false,
			commandMD = commandMD
		};

		if( structKeyExists( commandMD, 'functions' ) ) {
			// Capture the command's parameters
			for( var func in commandMD.functions ) {
				// Loop to find the "run()" method
				if( func.name == 'run' ) {
					commandData.parameters = func.parameters;
					
					// Grab completor annotations if they exists while we're here
					// We'll save these out in a struct indexed by param name for easy finding
					for( var param in func.parameters ) {
						if( structKeyExists( param, 'options' ) ) {
							// Turn comma-delimited list of static values into an array
							commandData.completor[ param.name ][ 'options' ] = listToArray( param.options );
						}
						if( structKeyExists( param, 'optionsUDF' ) ) {
							// Grab name of completor function for this param
							commandData.completor[ param.name ][ 'optionsUDF' ] = param.optionsUDF;
						}
					}
					
					break;
				}
			}			
		} else {
			commandData.parameters = [];
		}
		return commandData;
	}

	function addToDictionary( required command, required commandPath ) {
		// Build bracketed string of command path to allow special characters
		var commandPathBracket = '';
		var commandName = '';
		for( var item in listToArray( commandPath, '.' ) ) {
			commandPathBracket &= '[ "#item#" ]';
			commandName &= "#item# ";
		}

		// Register the command in our command dictionary
		evaluate( "instance.commands#commandPathBracket#[ '$' ] = command" );

		// And again here in this flat collection for help usage
		instance.flattenedCommands[ trim(commandName) ] = command;
	}

	/**
	 * run a command line
	 * @line.hint line to run
 	 **/
	function runCommandline( required string line ) {

		// Resolve the command they are wanting to run
		var commandChain = resolveCommand( line );
		
		// If nothing is returned, something bad happened (like an error instatiating the CFC)
		if( !commandChain.len() ) {
			return 'Command not run.';
		}

		var i = 0;
		// If piping commands, each one will be an item in the chain.
		// i.e. forgebox show | grep | more
		// Would result in three separate, chained commands.
		for( var commandInfo in commandChain ) {
			i++;

			// If nothing was found, bail out here.
			if( !commandInfo.found ) {
				shell.printError({message:'Command "#line#" cannot be resolved.  Please type "#trim( "help #listChangeDelims( commandInfo.commandString, ' ', '.' )#" )#" for assistance.'});
				return;
			}

			// For help commands squish all the parameters together into one exactly as typed
			if( listLast( commandInfo.commandReference.originalName, '.' ) == 'help' ) {
				var parameterInfo = {
					positionalParameters = [ arrayToList( commandInfo.parameters, ' ' ) ],
					namedParameters = {},
					flags = {}
				};
			// For normal commands, parse them out properly
			} else {
				var parameterInfo = parseParameters( commandInfo.parameters );
			}

			// Parameters need to be ALL positional or ALL named
			if( arrayLen( parameterInfo.positionalParameters ) && structCount( parameterInfo.namedParameters ) ) {
				shell.printError({message:"Please don't mix named and positional parameters, it makes me dizzy.#cr# #line#"});
				return;
			}

			// These are the parameters declared by the command CFC
			var commandParams = commandInfo.commandReference.parameters;

			// If this is not the first command in the chain,
			// set its first parameter with the output from the last command
			if( i > 1 ) {
				// If we're using named parameters and this command has at least one param defined
				if( structCount( parameterInfo.namedParameters ) ) {
					// Insert/overwrite the first param as our last result
					parameterInfo.namedParameters[ commandParams[1].name ?: '1' ] = result;
				} else {
					parameterInfo.positionalParameters.prepend( result );
				}
			}

			// If we're using postitional params, convert them to named
			if( arrayLen( parameterInfo.positionalParameters ) ) {
				parameterInfo.namedParameters = convertToNamedParameters( parameterInfo.positionalParameters, commandParams );
			}
			
			// Merge flags into named params
			mergeFlagParameters( parameterInfo );

			// Make sure we have all required params.
			parameterInfo.namedParameters = ensureRequiredParams( parameterInfo.namedParameters, commandParams );
	
			// Reset the printBuffer
			commandInfo.commandReference.CFC.reset();

			// If there are currently executing commands, flush out the print buffer from the last one
			// This will prevent the output from showing up out of order if one command nests a call to another.
			if( instance.callStack.len() ) {
				// Print anything in the buffer
				shell.printString( instance.callStack[1].commandReference.CFC.getResult() );
				// And reset it now that it's been printed.
				// This command can add more to the buffer once it's executing again.
				instance.callStack[1].commandReference.CFC.reset();
			}

			// Add command to the top of the stack
			instance.callStack.prepend( commandInfo );

			// Run the command
			try {
				var result = commandInfo.commandReference.CFC.run( argumentCollection = parameterInfo.namedParameters );
			} catch( any e ) {
				// Dump out anything the command had printed so far
				var result = commandInfo.commandReference.CFC.getResult();
				if( len( result ) ) {
					shell.printString( result & cr );
				}
				// Clean up a bit
				instance.callStack.clear();
				// Now, where were we?
				rethrow;
			}

			// Remove it from the stack
			instance.callStack.deleteAt( 1 );

			// If the command didn't return anything, grab its print buffer value
			if( isNull( result ) ) {
				result = commandInfo.commandReference.CFC.getResult();
			}


		} // End loop over command chain

		return result;

	}

	/**
	 * Take an array of parameters and parse them out as named or positional
	 * @parameters.hint The array of params to parse.
 	 **/
	function parseParameters( parameters ) {
		return parser.parseParameters( parameters );
	}

	/**
	 * Figure out what command to run based on the tokenized user input
	 * @line.hint A string containing the command and parameters that the user entered
 	 **/
	function resolveCommand( required string line ) {

		// Turn the users input into an array of tokens
		var tokens = parser.tokenizeInput( line );
		// This will hold the command chain. Usually just a single command,
		// but a pipe ("|") will chain together commands and pass the output of one along as the input to the next
		var commandsToResolve = [[]];
		var commandChain = [];

		// If this command has a pipe, we need to chain multiple commands
		var i = 0;
		for( var token in tokens ) {
			i++;
			// We've reached a pipe and there is at least one command resolved already and there are more tokens left
			if( token == '|' &&  commandsToResolve[ commandsToResolve.len() ].len() && i < tokens.len()  ) {
				// Add a new command
				commandsToResolve.append( [] );
			} else if( token == '>' &&  commandsToResolve[ commandsToResolve.len() ].len() && i < tokens.len()  ) {
				// Add a new command
				commandsToResolve.append( [ 'fileWrite' ] );
			} else if( token == '>>' &&  commandsToResolve[ commandsToResolve.len() ].len() && i < tokens.len()  ) {
				// Add a new command
				commandsToResolve.append( [ 'fileAppend' ] );
			} else {
				//Append this token to the last command
				commandsToResolve[ commandsToResolve.len() ].append( token );
			}
		}


		// command hierarchy
		var cmds = getCommandHierarchy();

		for( var commandTokens in commandsToResolve ) {

			tokens = commandTokens;

			// If command ends with "help", switch it around to call the root help command
			// Ex. "coldbox help" becomes "help coldbox"
			// Don't do this if we're already in a help command or endless recursion will ensue.
			if( tokens.len() > 1 && tokens.last() == 'help' && !inCommand( 'help' ) ) {
				// Move help to the beginning
				tokens.deleteAt( tokens.len() );
				tokens.prepend( 'help' );
			}
			
			// If the first token looks like a drive letter, then it's just a Windows user trying to "cd" to a different drive
			// A drive letter for these purposes will be defined as up to 3 letters folowed by a colon and an optional slash.
			if( tokens.len() && reFind( '^[a-z,A-Z]{1,3}:[\\,/]?$', tokens[1] ) ){
				var drive = tokens[1];
				// make sure the drive letter ends with a slash
				if( !( drive.endsWith( '\' ) || drive.endsWith( '/' ) ) ) {
					drive &= '\';
				}
				// This is the droid you're looking for
				tokens = [ 'cd', drive ];
			}

			var results = {
				commandString = '',
				commandReference = cmds,
				parameters = [],
				found = false,
				closestHelpCommand = 'help'
			};

			for( var token in tokens ) {

				// If we hit a dead end, then quit looking
				if( !structKeyExists( results.commandReference, token ) ) {
					break;
				}

				// Move the pointer
				results.commandString = listAppend( results.commandString, token, '.' );
				results.commandReference = results.commandReference[ token ];

				// If we've reached a command, we're done
				if( structKeyExists( results.commandReference, '$' ) ) {
					results.found = true;
					
					// Actual command data stored in a nested struct
					results.commandReference = results.commandReference[ '$' ];
					
					// Create the command CFC instance if neccessary
					var commandLoaded = lazyLoadCommandCFC( results.commandReference );
					// If there was an error loading the command
					if( !commandLoaded ) {
						// Error has already been displayed, so just pretend we didn't find anything.
						return [];
					}
					
					break;
				// If this is a folder, check and see if it has a "help" command
				} else {
					if( structKeyExists( results.commandReference, 'help' ) && structKeyExists( results.commandReference.help, '$' ) ) {
						results.closestHelpCommand = listChangeDelims( results.commandString, ' ', '.' ) & ' help';
					}
				}


			} // end for loop

			// If we found a command, carve the parameters off the end
			var commandLength = listLen( results.commandString, '.' );
			var tokensLength = arrayLen( tokens );
			if( results.found && commandLength < tokensLength ) {
				results.parameters = tokens.slice( commandLength+1 );
			}
			
			commandChain.append( results );

		} // end loop over commands to resolve

		// Return command chain
		return commandChain;

	}

	/**
	 * Takes a struct of command data and lazy loads the actual CFC isntance if neccessary
	 * @commandData.hint Struct created by registerCommand()
 	 **/
	private function lazyLoadCommandCFC( commandData ) {
		
		// Check for actual CFC instance, and lazy load if neccessary
		if( !structKeyExists( commandData, 'CFC' ) ) {
			// Create this command CFC
			try {
				commandData.CFC = wireBox.getInstance( commandData.fullCFCPath );
			// This will catch nasty parse errors so the shell can keep loading
			} catch( any e ) {
				systemOutput( 'Error creating command [#commandData.fullCFCPath#]#CR##CR#' );
				logger.error( 'Error creating command [#commandData.fullCFCPath#]. #e.message# #e.detail ?: ''#', e.stackTrace );
				// pretty print the exception
				shell.printError( e );
				return false;
			}
		} // CFC exists check
		return true;		
	}
	
	/**
	 * Looks at the call stack to determine if we're currently "inside" a command.
	 * Useful to prevent endless recursion.
	 * @command.hint Name of the command to look for as typed from the shell.  If empty, returns true for any command
 	 **/
	function inCommand( command='' ) {

		// If a command is provided, look for it in the call stack..
		if( len( command ) ) {
			for( var call in instance.callStack ) {
				// CommandString is a dot-delimted path
				if( call.commandString == listChangeDelims( command, ' ', '.' ) ) {
					return true;
				}
			}
			// Nope, not found
			return false;
		} else {
			// If no specific command given, just look for any thing in the stack
			return instance.callStack.len() ? true : false;
		}

	}

	/**
	 * return a list of base commands
 	 **/
	function listCommands() {
		return structKeyList( instance.flattenedCommands );
	}

	/**
	 * return the command structure
 	 **/
	function getCommands() {
		return instance.flattenedCommands;
	}

	/**
	 * return the nested command structure
 	 **/
	function getCommandHierarchy() {
		return instance.Commands;
	}

	/******************************************* PRIVATE ***************************************/

	/**
	 * load command CFC
	 * @baseCommandDirectory.hint The base directory for this command
	 * @cfc.hint CFC name that represents the command
	 * @commandPath.hint The relative dot-delimted path to the CFC starting in the commands dir
	 **/
	private function registerCommand( baseCommandDirectory, CFC, commandPath ) {

		// Strip cfc extension from filename
		var CFCName = mid( CFC, 1, len( CFC ) - 4 );
		var commandName = iif( len( commandPath ), de( commandPath & '.' ), '' ) & CFCName;
		// Build CFC's path
		var fullCFCPath = baseCommandDirectory & '.' & commandName;
		
		
		try {
			// Create a nice struct of command metadata
			var commandData = createCommandData( fullCFCPath, commandName );
		// This will catch nasty parse errors so the shell can keep loading
		} catch( any e ) {
			systemOutput( 'Error registering command [#fullCFCPath#]#CR##CR#' );
			logger.error( 'Error registering command [#fullCFCPath#]. #e.message# #e.detail ?: ''#', e.stackTrace );
			// pretty print the exception
			shell.printError( e );
			return;
		}

		// must extend commandbox.system.BaseCommand, can't be Application.cfc
		if( CFCName == 'Application' || !isCommandCFC( commandData ) ) {
			return;
		}

		// Add it to the command dictionary
		addToDictionary( commandData, commandPath & '.' & CFCName );

		// Register the aliases
		for( var alias in commandData.aliases ) {
			// Alias is allowed to be anything.  This means it may even overwrite another command already loaded.
			addToDictionary( commandData, listChangeDelims( trim( alias ), '.', ' ' ) );
		}
	}

	/**
	* checks if given cfc name is a valid command component
	*/
	function isCommandCFC( commandData ) localmode="true" {
		var meta = commandData.commandMD;
		
		// Make sure command extends BaseCommand
		var thisMeta = meta;
		while(true) {
			// Once we find BaseCommand kick out of the loop
			if(thisMeta.fullname=='commandbox.system.BaseCommand') {
				break;
			}
			// If we reach the end of the inheritance chain, we failed.
			if( !structKeyExists( thisMeta, 'extends' ) ) {
				return false;	
			}
			// Moving pointer
			thisMeta = thisMeta.extends;
		}
					
		// Make sure command has a run() method
		for( var func in meta.functions ) {
			// Loop to find the "run()" method
			if( func.name == 'run' ) {
				return true;
			}
		}
		
		// Didn't find run() method
		return false;
	}


	/**
	 * Make sure we have all required params
 	 **/
	private function ensureRequiredparams( userNamedParams, commandParams ) {
		// For each command param
		for( var param in commandParams ) {
			// If it's required and hasn't been supplied...
			if( param.required && !structKeyExists( userNamedParams, param.name ) ) {
				// ... Ask the user
				var message = 'Enter #param.name#';
				var value  	= "";
				// Verify hint
				if( structKeyExists( param, 'hint' ) ) {
					message &= ' (#param.hint#) :';
				}
				// ask value logic
				var askValue = function(){
					// Is this a boolean value
					if( structKeyExists( param, "type" ) and param.type == "boolean" ){
						return shell.confirm( message & "(Yes/No)" );
					} 
					// Strings
					else {
						return shell.ask( message );
					}
				};

				// Ask for value
				value = askValue();
				// Validate it
				while( param.required && !len( value ) ){
					shell.printString( "*Value is required* " );
					value = askValue();
				}
           		
           		// value entered matches the type!
           		userNamedParams[ param.name ] = value;
			}
		} // end for loop

		return userNamedParams;
	}

	/**
	 * Match positional parameters up with their names
 	 **/
	private function convertToNamedParameters( userPositionalParams, commandParams ) {
		var results = {};

		var i = 0;
		// For each param the user typed in
		for( var param in userPositionalParams ) {
			i++;
			// Figure out its name
			if( arrayLen( commandParams ) >= i ){
				results[ commandParams[i].name ] = param;
			// Extra user params just get assigned a name
			} else {
				results[ i ] = param;
			}
		}

		return results;
	}
	/**
	 * Merge flags into named parameters
 	 **/
	private function mergeFlagParameters( required struct parameterInfo ) {
		// Add flags into named params
		arguments.parameterInfo.namedParameters.append( arguments.parameterInfo.flags );
	}
		
}