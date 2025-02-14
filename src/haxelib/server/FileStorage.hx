/*
 * Copyright (C)2005-2016 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
package haxelib.server;

import sys.FileSystem;
import sys.io.*;
import haxe.io.Path;
import haxelib.server.Paths;
using Lambda;
#if neko
import neko.Web;
import aws.*;
import aws.s3.*;
import aws.s3.model.*;
import aws.transfer.*;
#end

/**
	`FileStorage` is an abstraction to a file system.
	It maps relative paths to absolute paths, effectively hides the actual location of the storage.
*/
class FileStorage {
	static function log(msg:String, ?pos:haxe.PosInfos) {
		#if neko
		Web.logMessage(msg);
		#else
		trace(msg, pos);
		#end
	}

	/**
		An static instance of `FileStorage` that everyone use.
		One should not create their own instance of `FileStorage` except when testing.

		When both the enviroment variables, HAXELIB_S3BUCKET and AWS_DEFAULT_REGION, are set,
		`instance` will be a `S3FileStorage`. Otherwise, it will be a `LocalFileStorage`.
	*/
	static public var instance(get, null):FileStorage;
	static function get_instance() return instance != null ? instance : instance = {
		var vars = [
			Sys.getEnv("HAXELIB_S3BUCKET"),
			Sys.getEnv("AWS_DEFAULT_REGION"),
			Sys.getEnv("HAXELIB_S3BUCKET_MOUNTED_PATH"),
		];
		switch (vars) {
			#if neko
			case [bucket, region, null] if (bucket != null && region != null):
				var endpoint = Sys.getEnv("HAXELIB_S3BUCKET_ENDPOINT");
				log('using S3FileStorage with bucket $bucket in ${region} ${endpoint == null ? "" : endpoint}');
				new S3FileStorage(Paths.CWD, bucket, region, endpoint);
			#end
			case [bucket, region, mounted] if (bucket != null && region != null && mounted != null):
				log('using LocalFileStorage with S3 mounted path');
				new LocalFileStorage(mounted);
			case _:
				log('using LocalFileStorage');
				new LocalFileStorage(Paths.CWD);
		}
	}

	/**
		Request reading `file` in the function `f`.
		`file` should be the relative path to the required file, e.g. `files/3.0/library.zip`.
		If the file does not exist, an error will be thrown, and `f` will not be called.
		If `file` exist, its abolute path will be given to `f` as input.
		It only guarantees `file` exists and the abolute path to it is valid within the call of `f`.
	*/
	public function readFile<T>(file:RelPath, f:AbsPath->T):T
		return throw "should be implemented by subclass";

	/**
		Request writing `file` in the function `f`.
		`file` should be a relative path to the required file, e.g. `files/3.0/library.zip`.
		Any of the parent directories of `file` that doesn't exist will be created.
		The mapped abolute path of `file` will be given to `f` as input.
		The abolute path to `file` may and may not contain previously written file.
	*/
	public function writeFile<T>(file:RelPath, f:AbsPath->T):T
		return throw "should be implemented by subclass";

	/**
		Copy existing local `srcFile` to the storage as `dstFile`.
		Existing `dstFile` will be overwritten.
		If `move` is true, `srcFile` will be deleted, unless `dstFile` happens to located
		at the same path of `srcFile`.
	*/
	public function importFile<T>(srcFile:AbsPath, dstFile:RelPath, move:Bool):Void
		throw "should be implemented by subclass";

	/**
		Delete `file` in the storage.
		It will be a no-op if `file` does not exist.
	*/
	public function deleteFile(file:RelPath):Void
		throw "should be implemented by subclass";

	function assertAbsolute(path:String):Void {
		#if (haxe_ver >= 3.2) // Path.isAbsolute is added in haxe 3.2
		if (!Path.isAbsolute(path))
			throw '$path is not absolute.';
		#end
	}

	function assertRelative(path:String):Void {
		#if (haxe_ver >= 3.2) // Path.isAbsolute is added in haxe 3.2
		if (Path.isAbsolute(path))
			throw '$path is not relative.';
		#end
	}
}

class LocalFileStorage extends FileStorage {
	/**
		The local directory of the file storage.
	*/
	public var path(default, null):AbsPath;

	/**
		Create a `FileStorage` located at a local directory specified by an absolute `path`.
	*/
	public function new(path:AbsPath):Void {
		assertAbsolute(path);
		this.path = path;
	}

	override public function readFile<T>(file:RelPath, f:AbsPath->T):T {
		assertRelative(file);
		var file:AbsPath = Path.join([path, file]);
		if (!FileSystem.exists(file))
			throw '$file does not exist.';
		return f(file);
	}

	override public function writeFile<T>(file:RelPath, f:AbsPath->T):T {
		assertRelative(file);
		var file:AbsPath = Path.join([path, file]);
		FileSystem.createDirectory(Path.directory(file));
		return f(file);
	}

	override public function importFile<T>(srcFile:AbsPath, dstFile:RelPath, move:Bool):Void {
		var localFile:AbsPath = Path.join([path, dstFile]);
		if (
			FileSystem.exists(localFile) &&
			FileSystem.fullPath(localFile) == FileSystem.fullPath(srcFile)
		) {
			// srcFile already located at dstFile
			return;
		}
		FileSystem.createDirectory(Path.directory(localFile));
		File.copy(srcFile, localFile);
		if (move)
			FileSystem.deleteFile(srcFile);
	}

	override public function deleteFile(file:RelPath):Void {
		var localFile:AbsPath = Path.join([path, file]);
		if (FileSystem.exists(localFile))
			FileSystem.deleteFile(localFile);
	}
}

#if neko
class S3FileStorage extends FileStorage {
	/**
		The local directory for caching.
	*/
	public var localPath(default, null):AbsPath;

	/**
		The S3 bucket name.
	*/
	public var bucketName(default, null):String;

	/**
		The region where the S3 bucket is located.
		e.g. 'us-east-1'
	*/
	public var bucketRegion(default, null):aws.Region;

	/**
		The public endpoint of the S3 bucket.
		e.g. 'http://${bucket}.s3-website-${region}.amazonaws.com/'
	*/
	public var bucketEndpointOverride(default, null):String;

	var s3Client(default, null):S3Client;
	var transferClient(default, null):TransferClient;

	static var awsInited = false;

	public function new(localPath:AbsPath, bucketName:String, bucketRegion:String, ?bucketEndpointOverride:String):Void {
		assertAbsolute(localPath);
		this.localPath = localPath;
		this.bucketName = bucketName;
		this.bucketRegion = bucketRegion;
		this.bucketEndpointOverride = bucketEndpointOverride;

		if (!awsInited) {
			Aws.initAPI();
			awsInited = true;
		}

		this.transferClient = new TransferClient(this.s3Client = new S3Client(bucketRegion, bucketEndpointOverride));
	}

	override public function readFile<T>(file:RelPath, f:AbsPath->T):T {
		assertRelative(file);
		var s3Path = Path.join(['s3://${bucketName}', file]);
		var localFile:AbsPath = Path.join([localPath, file]);
		FileSystem.createDirectory(Path.directory(localFile));
		if (!FileSystem.exists(localFile)) {
			var request = transferClient.downloadFile(localFile, bucketName, file);
			while (!request.isDone()) {
				Sys.sleep(0.01);
			}
			if (!request.completedSuccessfully()) {
				throw 'failed to download ${s3Path} to ${localFile}\n${request.getFailure()}';
			}
			if (!FileSystem.exists(localFile)) {
				throw 'failed to download ${s3Path} to ${localFile}';
			}
		}
		return f(localFile);
	}

	function uploadToS3(localFile:AbsPath, file:RelPath, contentType = "application/octet-stream") {
		var s3Path = Path.join(['s3://${bucketName}', file]);
		var request = transferClient.uploadFile(localFile, bucketName, file, contentType);
		while (!request.isDone()) {
			Sys.sleep(0.01);
		}
		switch (request.getFailure()) {
			case null:
				//pass
			case failure:
				throw 'failed to upload ${localFile} to ${s3Path}\n${failure}';
		}
	}

	override public function writeFile<T>(file:RelPath, f:AbsPath->T):T {
		assertRelative(file);
		var localFile:AbsPath = Path.join([localPath, file]);
		if (!FileSystem.exists(localFile))
			throw '$localFile does not exist';
		FileSystem.createDirectory(Path.directory(localFile));
		var r = f(localFile);
		uploadToS3(localFile, file);
		return r;
	}

	override public function importFile<T>(srcFile:AbsPath, dstFile:RelPath, move:Bool):Void {
		var localFile:AbsPath = Path.join([localPath, dstFile]);
		if (
			FileSystem.exists(localFile) &&
			FileSystem.fullPath(localFile) == FileSystem.fullPath(srcFile)
		) {
			// srcFile already located at dstFile
			uploadToS3(localFile, dstFile);
			return;
		}
		FileSystem.createDirectory(Path.directory(localFile));
		File.copy(srcFile, localFile);
		uploadToS3(localFile, dstFile);
		if (move)
			FileSystem.deleteFile(srcFile);
	}

	override public function deleteFile(file:RelPath):Void {
		var localFile:AbsPath = Path.join([localPath, file]);
		if (FileSystem.exists(localFile))
			FileSystem.deleteFile(localFile);

		var del = new DeleteObjectRequest();
		del.setBucket(bucketName);
		del.setKey(file);
		try {
			s3Client.deleteObject(del);
		} catch (e:Dynamic) {
			// maybe the object does not exist
		}
	}
}
#end